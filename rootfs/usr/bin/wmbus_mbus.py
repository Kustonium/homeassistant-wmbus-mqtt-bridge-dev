#!/usr/bin/env python3
"""The wired M-Bus instance's output, read in one process (14-mbus.sh).

`consume` replaces the bash loop behind the third wmbusmeters instance
(mbus_log_console_line + mbus_consume_line), line for line:

- every decoder line is appended to the console log as
  "HH:MM:SS<TAB>reading<TAB>line" (the reading number steps on each accepted
  telegram), and the log is cut to its last 2000 lines every 500 lines - in
  place, as tee and the WebUI keep the file open;
- an accepted telegram updates the per-meter id, last-ok time and address
  clash (a name answering with a new id), loses its rssi_dbm (0 on a wire)
  and is handed back to bash for publishing: Discovery, state and the meter
  table belong to the radio path's code there;
- the decoder's own words name the failure causes the JSON never carries,
  and become the traffic state of status_mbus.json (transitions only).

Requests to the bash loop behind it, one per line, four fields separated by
0x1F (which `read` keeps, so empty fields survive), in the order of the
decoder's output: "tg" <name> <id> <telegram> and "log" "" "" <line>. The
line is always the last field, which `read` hands over whole; a newline in
it (jq printing several values) travels as 0x1E.
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from typing import Dict, List

import bridge_ledger as bl

SEP = "\x1f"
NEWLINE = "\x1e"
LOG_MAX_LINES = 2000
TRIM_EVERY = 500


def jq_c_del(line: str, key: str) -> str:
    """`line="$(echo "$line" | jq -c 'del(.key)' 2>/dev/null || printf '%s' "$line")"`.

    Every JSON value of the line is one input; the outputs written before an
    error stay, and the original line follows them when jq fails.
    """
    text = line + "\n"
    out: List[str] = []
    failed = _garbage(text)
    for v in bl.jq_values(text):
        if v is None:
            out.append("null")
        elif isinstance(v, dict):
            v = dict(v)
            v.pop(key, None)
            out.append(bl.jq_dumps(v))
        else:
            failed = True  # del() of a key on a number, string, array or boolean
    result = "".join(o + "\n" for o in out)
    if failed:
        result += line
    return result.rstrip("\n")


def _garbage(text: str) -> bool:
    i, n = 0, len(text)
    while True:
        while i < n and text[i] in bl._JQ_WS:
            i += 1
        if i >= n:
            return False
        try:
            _, i = bl._DECODER.raw_decode(text, i)
        except ValueError:
            return True


def options_value(path: str, key: str, fallback: str) -> str:
    """mbus_opt: `jq -r --arg k KEY --arg d FALLBACK '.[$k] // $d' options.json`."""
    try:
        with open(path, "rb") as fh:
            text = bl._s(fh.read())
    except OSError:
        return fallback
    out = []
    for v in bl.jq_values(text):
        if not isinstance(v, dict):
            if v is None:
                out.append(fallback)
                continue
            return fallback  # jq fails: `|| printf fallback` follows what it printed
        x = v.get(key)
        x = fallback if x is None or x is False else x
        out.append(x if isinstance(x, str) else bl._jq_pretty(x))
    return "\n".join(out).rstrip("\n") if out else fallback


class MbusBook:
    def __init__(self, a: argparse.Namespace, out=None, err=None) -> None:
        self.a = a
        self.out = out if out is not None else sys.stdout
        self.err = err if err is not None else sys.stderr
        self.state = a.state
        self.read_seq = 0
        self.since_trim = 0
        self.last_id: Dict[str, str] = {}
        self.last_ok: Dict[str, int] = {}
        self.clash: Dict[str, str] = {}

    def request(self, *fields: str) -> None:
        try:
            self.out.write(SEP.join(fields) + "\n")
            self.out.flush()
        except OSError:
            pass

    def line(self, line: str) -> None:
        self.console(line)
        self.consume(line)

    @staticmethod
    def is_telegram(line: str) -> bool:
        return line.startswith("{") and '"_":"telegram"' in line

    def console(self, line: str) -> None:
        """mbus_log_console_line."""
        if self.is_telegram(line):
            self.read_seq += 1
        stamp = time.strftime("%H:%M:%S", time.localtime(bl.now()))
        try:
            with open(self.a.log, "ab") as fh:
                fh.write(bl._b(f"{stamp}\t{self.read_seq}\t{line}\n"))
        except OSError:
            pass

    def trim(self) -> None:
        """mbus_trim_log: keep the tail, rewritten in place (not renamed over)."""
        lines = bl._read_lines(self.a.log)
        if len(lines) <= LOG_MAX_LINES:
            return
        try:
            with open(self.a.log, "wb") as fh:
                fh.write(b"".join(ln + b"\n" for ln in lines[-LOG_MAX_LINES:]))
        except OSError:
            pass

    def consume(self, line: str) -> None:
        """mbus_consume_line."""
        self.since_trim += 1
        if self.since_trim >= TRIM_EVERY:
            self.since_trim = 0
            self.trim()
        if self.is_telegram(line):
            meter = bl.normalize_id(bl.jq_r(line, (".id",)))
            name = bl.jq_r(line, (".name",))
            if name and meter:
                prev = self.last_id.get(name, "")
                if prev and prev != meter:
                    print(f"[wmbus-bridge][WARN] M-Bus: '{name}' answered with id={meter} but previously "
                          f"{prev} -> two meters on one address?", file=self.err, flush=True)
                    bl.append_event(self.a.events_file, "warn", f"M-Bus address clash on '{name}': {prev} vs {meter}")
                    self.clash[name] = prev
                self.last_id[name] = meter
                self.last_ok[name] = int(bl.now())
            if bl._ID8.fullmatch(meter):
                line = jq_c_del(line, "rssi_dbm")
            # bash publishes it (exclude patterns by name, Discovery, state)
            # and echoes it, as mbus_consume_line did.
            self.request("tg", name, meter, line.replace("\n", NEWLINE))
            self.state = "ok"
            self.write_status("ok")
            return
        if "no 0x68 byte found" in line:
            self.set_state("not_mbus_traffic")
        elif "expected checksum" in line:
            self.set_state("damaged_frames")
        elif "did not send a response" in line:
            # A named cause outranks plain silence.
            if self.state not in ("not_mbus_traffic", "damaged_frames"):
                self.set_state("no_reply")
        elif "no bus specified for meter" in line or "SpecifiedDeviceNotFound" in line:
            self.set_state("bus_down")
        self.request("log", "", "", line)

    def set_state(self, new: str) -> None:
        """mbus_set_state: transitions only."""
        if new == self.state:
            return
        self.state = new
        self.write_status(new)

    def write_status(self, state: str) -> None:
        """mbus_write_status."""
        meters = {name: {"id": self.last_id[name], "last_ok_epoch": self.last_ok.get(name, 0),
                         "clash_with": self.clash.get(name, "")} for name in self.last_id}
        doc = {"state": state, "device": options_value(self.a.options, "mbus_device", ""),
               "bus_alias": self.a.alias, "meters_configured": int(self.a.configured or 0),
               "meters_skipped": int(self.a.skipped or 0), "meters": meters, "updated": int(bl.now())}
        path = self.a.status_file
        try:
            with open(path + ".tmp", "wb") as fh:
                fh.write(bl._b(bl._jq_pretty(doc) + "\n"))
            os.replace(path + ".tmp", path)
        except OSError:
            pass


def run(book: MbusBook, stream=None) -> None:
    stream = stream if stream is not None else sys.stdin.buffer
    for raw in stream:
        if not raw.endswith(b"\n"):  # `read` does not hand over an unterminated last line
            continue
        try:
            book.line(bl._s(raw[:-1]))
        except Exception as exc:  # one bad line must not stop the console
            print(f"[wmbus-bridge][WARN] M-Bus: decoder line skipped: {exc!r}", file=sys.stderr, flush=True)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="mode", required=True)
    c = sub.add_parser("consume", help="output of the wired M-Bus wmbusmeters instance")
    for name in ("log", "status-file", "options", "events-file"):
        c.add_argument(f"--{name}", required=True)
    c.add_argument("--alias", default="MAIN")
    c.add_argument("--configured", default="0")
    c.add_argument("--skipped", default="0")
    c.add_argument("--state", default="starting", help="MBUS_TRAFFIC_STATE when the instance starts")
    a = ap.parse_args(argv)
    run(MbusBook(a))
    return 0


if __name__ == "__main__":
    sys.exit(main())
