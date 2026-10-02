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

import fcntl
import os
import sys
import tempfile
import time
from contextlib import contextmanager
from typing import Callable, Dict, Iterator, List, Optional, Tuple

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


def tsv_upsert(path: str, key: str, row: str) -> None:
    """_tsv_upsert: drop the rows keyed `key`, append `row`, atomically."""
    k = key.encode()
    with locked(path):
        lines = [ln for ln in _read_lines(path) if _first_field(ln) != k]
        lines.append(row.encode())
        _replace_with(path, lines)


def tsv_remove(path: str, key: str) -> None:
    """_tsv_remove_id: drop the rows keyed `key`; no-op for a missing file."""
    if not os.path.isfile(path):
        return
    k = key.encode()
    with locked(path):
        lines = [ln for ln in _read_lines(path) if _first_field(ln) != k]
        _replace_with(path, lines)


def append_locked(path: str, line: str) -> None:
    """Append one line under the file's lock (the JSONL history appends)."""
    with locked(path):
        with open(path, "ab") as fh:
            fh.write(line.encode() + b"\n")


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
# Message handlers by mode name ("rssi", "rx", ...). Registered by the paths
# that have been moved here.
MODES: Dict[str, Handler] = {}


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


def main(argv: Optional[List[str]] = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1 or argv[0] not in MODES:
        modes = ", ".join(sorted(MODES)) or "none yet"
        print(f"usage: bridge_ledger.py <mode>  (modes: {modes})", file=sys.stderr)
        return 2
    run(MODES[argv[0]])
    return 0


if __name__ == "__main__":
    sys.exit(main())
