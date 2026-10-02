#!/usr/bin/env python3
"""Per-message bookkeeping of the bridge, in one long-lived process.

WHY
---
Every MQTT message from every ESP used to be booked by bash: the RAW counter,
the per-board tracker, the /rx and rssi/<id> subscribers and the LISTEN block
handler. Each of them started tens of processes per message (awk, jq, mv,
mktemp, flock, date and $(...) subshells - see tests/test_perf_fork_budget.sh),
which on a 5-ESP site kept a CPU core busy doing nothing but process start-up.
This module does the same bookkeeping in-process. It is introduced one path at
a time; each path keeps its bash implementation until it is switched over.

CONTRACT
--------
* Files keep their exact formats. webui.py and the bash code that stays (the
  decode loop, tickers, inject_rssi_into_json) read them unchanged.
* Locking is shared with bash. flock(1) and fcntl.flock() take the same kind of
  lock (BSD flock on an open file description), so taking "<file>.lock" here
  serialises with _tsv_upsert and the other locked helpers in 03-tsv.sh.
* Temporary files are created next to the target as "<file>.tmp.XXXXXX" with
  mode 0600, like mktemp(1), and moved into place with one rename.
* Keys are compared as strings. BusyBox awk in the add-on image compares two
  numeric-looking fields numerically, so the bash helpers treat ids such as
  00001000 and 0001E003 as equal (both are 1000) and one row replaces the
  other. Here they stay two rows, which is what the ids mean.
* No MQTT client library: input is the stdout of mosquitto_sub -F '%t\\t%p',
  one "topic<TAB>payload" message per line. A message that fails is reported
  on stderr and skipped; the process never exits because of its input.
"""
from __future__ import annotations

import argparse
import fcntl
import glob
import os
import re
import sys
import tempfile
import time
from contextlib import contextmanager
from typing import Callable, Iterator, List, Optional, Set, Tuple

# The clock every handler reads. Tests replace it to get fixed timestamps.
now: Callable[[], float] = time.time


@contextmanager
def locked(path: str) -> Iterator[None]:
    """Hold the exclusive lock bash takes with `( flock -x 9 ...) 9>"$path.lock"`."""
    fd = os.open(path + ".lock", os.O_WRONLY | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)  # closing the descriptor releases the lock


def _read_lines(path: str) -> List[bytes]:
    """Lines of a file without their newline; a missing file has none."""
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except FileNotFoundError:
        return []
    if not data:
        return []
    lines = data.split(b"\n")
    if data.endswith(b"\n"):
        lines.pop()
    return lines


def _replace_with(path: str, lines: List[bytes]) -> None:
    """Write lines to a fresh temporary file and rename it over path."""
    directory, base = os.path.split(path)
    fd, tmp = tempfile.mkstemp(prefix=base + ".tmp.", dir=directory or ".")
    try:
        with os.fdopen(fd, "wb") as fh:
            for line in lines:
                fh.write(line + b"\n")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _first_field(line: bytes) -> bytes:
    return line.split(b"\t", 1)[0]


def _b(text: str) -> bytes:
    """Back to the exact bytes that arrived (see _s)."""
    return text.encode("utf-8", "surrogateescape")


def _s(data: bytes) -> str:
    """Text for processing; bytes that are not UTF-8 survive the round trip."""
    return data.decode("utf-8", "surrogateescape")


def tsv_upsert(path: str, key: str, row: str) -> None:
    """_tsv_upsert: drop the rows keyed `key`, append `row`, atomically."""
    k = _b(key)
    with locked(path):
        lines = [ln for ln in _read_lines(path) if _first_field(ln) != k]
        lines.append(_b(row))
        _replace_with(path, lines)


def tsv_remove(path: str, key: str) -> None:
    """_tsv_remove_id: drop the rows keyed `key`; no-op for a missing file."""
    if not os.path.isfile(path):
        return
    k = _b(key)
    with locked(path):
        lines = [ln for ln in _read_lines(path) if _first_field(ln) != k]
        _replace_with(path, lines)


def append_locked(path: str, line: str) -> None:
    """Append one line under the file's lock (the JSONL history appends)."""
    with locked(path):
        with open(path, "ab") as fh:
            fh.write(_b(line) + b"\n")


def trim_locked(path: str, max_lines: int, keep_lines: int) -> None:
    """_trim_esp_rx_history: above max_lines, keep only the last keep_lines."""
    if not os.path.isfile(path):
        return
    with locked(path):
        lines = _read_lines(path)
        if len(lines) <= max_lines:
            return
        _replace_with(path, lines[-keep_lines:] if keep_lines > 0 else [])


def split_message(line: bytes) -> Tuple[bytes, bytes]:
    """Split one mosquitto_sub line the way `IFS=$'\\t' read -r topic payload` does.

    TAB is IFS whitespace there, so leading and trailing tabs are dropped and a
    run of tabs counts as one separator; spaces are kept.
    """
    line = line.rstrip(b"\n").strip(b"\t")
    topic, sep, payload = line.partition(b"\t")
    if sep:
        payload = payload.lstrip(b"\t")
    return topic, payload


Handler = Callable[[bytes, bytes], None]

_HEX8 = re.compile(r"[0-9A-Fa-f]{8}")
_NEG_INT = re.compile(r"-[0-9]+")


def bash_int(text: str) -> Optional[int]:
    """A decimal-looking string as bash arithmetic reads it, None where bash errors.

    A leading 0 makes bash read the digits as octal ("-070" is -56), and 8 or 9
    after it is an error, which the bash handlers treat as a rejected value.
    """
    sign = -1 if text.startswith("-") else 1
    digits = text.lstrip("-")
    try:
        if len(digits) > 1 and digits.startswith("0"):
            return sign * int(digits, 8)
        return sign * int(digits, 10)
    except ValueError:
        return None


def meter_ids_in(meter_dir: str) -> Set[str]:
    """Configured meter ids: the id= lines of METER_DIR/meter-* (_rssi_load_wanted).

    Like `while IFS= read -r` there, a line is taken verbatim and a last line
    without a newline is not read at all.
    """
    wanted: Set[str] = set()
    for path in glob.glob(os.path.join(meter_dir, "meter-*")):
        if not os.path.isfile(path):
            continue
        try:
            with open(path, "rb") as fh:
                complete_lines = fh.read().split(b"\n")[:-1]
        except OSError:
            continue
        for line in complete_lines:
            text = _s(line)
            if text.startswith("id=") and _HEX8.fullmatch(text[3:]):
                wanted.add(text[3:].upper())
    return wanted


class RssiBook:
    """_esp_rssi_handle_message: last RSSI per (meter, board) for configured meters.

    status_rssi.tsv: id<TAB>dbm<TAB>board<TAB>epoch, one row per (id, board).
    """

    RELOAD_S = 30

    def __init__(self, meter_dir: str, rssi_file: str) -> None:
        self.meter_dir = meter_dir
        self.rssi_file = rssi_file
        self.wanted: Set[str] = set()
        self.wanted_at = 0

    def __call__(self, topic_b: bytes, payload_b: bytes) -> None:
        if not payload_b:
            return
        topic, val = _s(topic_b), _s(payload_b)
        # Topic tail after the last ".../rssi/" is the meter id.
        meter_id = topic.rsplit("/rssi/", 1)[-1]
        if not _HEX8.fullmatch(meter_id):
            return
        meter_id = meter_id.upper()
        ts = int(now())
        if ts - self.wanted_at >= self.RELOAD_S:
            self.wanted = meter_ids_in(self.meter_dir)
            self.wanted_at = ts
        if meter_id not in self.wanted:
            return
        # Board = topic segment between "wmbus/" and the first "/rssi/".
        board = topic[len("wmbus/"):] if topic.startswith("wmbus/") else topic
        board = board.split("/rssi/", 1)[0]
        # A plausible measured level only; the firmware's "no data" sentinels
        # (1, 0, -127) must never become a reading.
        if not _NEG_INT.fullmatch(val):
            return
        dbm = bash_int(val)
        if dbm is None or not -125 <= dbm <= -1:
            return
        rssi_upsert(self.rssi_file, meter_id, board, f"{meter_id}\t{val}\t{board}\t{ts}")


def rssi_upsert(path: str, meter_id: str, board: str, row: str) -> None:
    """_rssi_tsv_upsert: replace the row of (meter_id, board), keep the other boards."""
    k1, k3 = _b(meter_id), _b(board)
    with locked(path):
        kept = []
        for line in _read_lines(path):
            fields = line.split(b"\t")
            if fields[0] != k1 or (fields[2] if len(fields) > 2 else b"") != k3:
                kept.append(line)
        kept.append(_b(row))
        _replace_with(path, kept)


def run(handler: Handler, stream=None, err=None) -> None:
    """Feed every line of stream to handler until EOF; a failing message is skipped."""
    stream = stream if stream is not None else sys.stdin.buffer
    err = err if err is not None else sys.stderr
    for raw in stream:
        topic, payload = split_message(raw)
        try:
            handler(topic, payload)
        except Exception as exc:  # one bad message must not stop the bookkeeping
            print(f"[wmbus-bridge][WARN] ledger: message on {topic!r} skipped: {exc!r}",
                  file=err, flush=True)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="bridge_ledger.py")
    modes = parser.add_subparsers(dest="mode", required=True)
    rssi = modes.add_parser("rssi", help="wmbus/<board>/rssi/<meter_id> messages")
    rssi.add_argument("--meter-dir", required=True)
    rssi.add_argument("--rssi-file", required=True)
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    try:
        args = _parser().parse_args(argv)
    except SystemExit as exc:  # usage errors: report, never raise out of main
        return int(exc.code or 0)
    if args.mode == "rssi":
        run(RssiBook(args.meter_dir, args.rssi_file))
    return 0


if __name__ == "__main__":
    sys.exit(main())
