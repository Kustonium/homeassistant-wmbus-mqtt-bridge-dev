"""wmbus_mbus.py consume against the bash loop it replaces (14-mbus.sh:
mbus_log_console_line + mbus_consume_line, kept as _mbus_consume_bash).

One recorded decoder output goes through _mbus_consume_bash and through
_mbus_consume_stage (wmbus_mbus.py and the bash loop behind it), each in its
own directory. The publishing functions are stubs that record what they get,
with the exclude patterns set for the meter at that moment. Compared: the
console log (the HH:MM:SS stamp aside - bash reads the wall clock), the
status file, the events file, the stdout and stderr lines and the publish
records.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIB_DIR = ROOT / "rootfs" / "usr" / "bin" / "bridge-lib"
BIN = ROOT / "rootfs" / "usr" / "bin"
NOW = 1790935200


def telegram(name, mid, extra=""):
    n = f'"name":"{name}",' if name is not None else ""
    return f'{{"_":"telegram","media":"water","meter":"auto",{n}"id":"{mid}","total_m3":1.5,"rssi_dbm":0{extra}}}'


CORPUS = [
    "Started config mbus on MAIN=/dev/ttyUSB0:mbus:2400",
    telegram("sim", "10000284"),
    "(mbus) meter sim did not send a response!",
    "wmbusmeters: no 0x68 byte found, skipping",
    "(mbus) meter sim did not send a response!",
    telegram("sim", "77000284", ',"x":[1,{"y":null}]'),
    telegram("other", "10000285"),
    telegram(None, "10000286"),
    telegram("bad", "zz"),
    telegram("sim", "77000284") + " junk",
    '{"_":"telegram","name":"sim","id":"77000284","rssi_dbm":0} {"a":1}',
    "(mbus) expected checksum 0x12 but got 0x34",
    "(mbus) SpecifiedDeviceNotFound /dev/ttyUSB0",
    "(mbus) meter sim did not send a response!",
    "no bus specified for meter sim",
    "\ttabbed\tline\t",
    "",
    "line with \x1f unit separator",
]


class MbusConsumerTests(unittest.TestCase):
    maxDiff = None
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_side(self, side, corpus, state="starting"):
        d = os.path.join(self.tmp, side)
        os.makedirs(d)
        Path(d, "options.json").write_text(json.dumps({"mbus_device": "/dev/ttyUSB0", "mbus_enabled": True}))
        Path(d, "corpus").write_text("".join(line + "\n" for line in corpus))
        clock = os.path.join(d, "clock")
        os.makedirs(clock)
        Path(clock, "sitecustomize.py").write_text(
            "import time\ntime.time = lambda: float(%d)\n" % NOW)
        stage = "_mbus_consume_bash" if side == "bash" else "_mbus_consume_stage"
        script = "\n".join([
            "set -uo pipefail",
            *(f"source '{p}'" for p in sorted(LIB_DIR.glob("*.sh"))),
            f"BASE='{d}'", f"RUNTIME='{d}'", f"OPTIONS_JSON='{d}/options.json'",
            f"STATUS_EVENTS_FILE='{d}/events.tsv'", f"MBUS_LOG='{d}/console.log'",
            f"MBUS_STATUS_FILE='{d}/status_mbus.json'", f"MBUS_CONSUMER='{BIN}/wmbus_mbus.py'",
            "MBUS_BUS_ALIAS=MAIN", "MBUS_METERS_OK=2", "MBUS_METERS_SKIPPED=1",
            f"MBUS_TRAFFIC_STATE='{state}'", "STATE_PREFIX=wmbusmeters", "STATE_RETAIN=false",
            "MBUS_EXCLUDE_BY_NAME[sim]='foo_* bar'", "MBUS_EXCLUDE_BY_NAME[other]='x'",
            "LOGLEVEL=normal",
            f"epoch_now() {{ echo {NOW}; }}", "iso_now() { echo 2026-10-02T10:00:00+00:00; }",
            f"rec() {{ printf '%s\\n' \"$*\" >> '{d}/published'; }}",
            "status_meter_seen() { rec meter_seen \"$1\"; }",
            "emit_discovery_from_json() { local k; for k in \"${!METER_EXCLUDE_FIELDS[@]}\"; do "
            "rec exclude \"$k=${METER_EXCLUDE_FIELDS[$k]}\"; done; rec discovery \"$1\"; }",
            "mqtt_pub() { rec pub \"$1\" \"$2\" \"$3\"; }",
            "status_mark_discovery_published() { rec marked; }", "write_status_json() { rec status; }",
            f"{stage} < '{d}/corpus' > '{d}/stdout' 2> '{d}/stderr'",
        ])
        subprocess.run(["bash", "-c", script], check=True, timeout=120,
                       env=dict(os.environ, PYTHONPATH=clock, TZ="UTC"))
        out = {}
        for name in ("console.log", "status_mbus.json", "events.tsv", "stdout", "stderr", "published"):
            p = Path(d, name)
            text = p.read_text() if p.exists() else None
            if name == "console.log" and text is not None:
                text = "".join("HH:MM:SS" + ln[8:] + "\n" for ln in text.splitlines())
            if name == "status_mbus.json" and text is not None:
                text = json.loads(text)
            out[name] = text
        self.assertFalse(os.path.exists(os.path.join(d, "status_mbus.json.tmp")))
        return out

    def compare(self, corpus, state="starting"):
        b = self.run_side("bash", corpus, state)
        shutil.move(os.path.join(self.tmp, "bash"), os.path.join(self.tmp, "bash.done"))
        p = self.run_side("py", corpus, state)
        shutil.rmtree(os.path.join(self.tmp, "bash.done"))
        shutil.rmtree(os.path.join(self.tmp, "py"))
        for name in b:
            self.assertEqual(p[name], b[name], name)
        return p

    def test_corpus(self):
        out = self.compare(CORPUS)
        self.assertEqual(out["status_mbus.json"]["meters"]["sim"]["clash_with"], "10000284")
        self.assertIn("exclude 10000284=foo_* bar", out["published"])
        self.assertNotIn('"rssi_dbm"', out["published"].split("discovery ", 1)[1].split("\n")[0])
        self.assertIn("M-Bus address clash on 'sim'", out["events.tsv"])

    def test_states(self):
        for start, lines in (("no_meters", ["(mbus) meter sim did not send a response!"]),
                             ("damaged_frames", ["(mbus) meter sim did not send a response!"]),
                             ("ok", ["wmbusmeters: no 0x68 byte found"]),
                             ("starting", [])):
            with self.subTest(start=start):
                self.compare(lines, start)

    def test_status_on_every_telegram(self):
        # The state stays "ok"; the second meter still reaches the status file.
        out = self.compare([telegram("sim", "10000284"), telegram("other", "10000285")])
        self.assertIn("other", out["status_mbus.json"]["meters"])

    def test_trim(self):
        corpus = [f"poll line {i}" for i in range(2600)] + [telegram("sim", "10000284")]
        out = self.compare(corpus)
        self.assertEqual(len(out["console.log"].splitlines()), 2000 + 101)  # cut at the 2500th line


if __name__ == "__main__":
    unittest.main()
