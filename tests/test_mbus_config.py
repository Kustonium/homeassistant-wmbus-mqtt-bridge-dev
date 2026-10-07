"""wmbus_mbus.py config against write_mbus_conf + refresh_mbus_meter_files
(14-mbus.sh), through _mbus_configure in both modes.

Each options.json variant runs _mbus_configure with MBUS_CONFIG_IN_PYTHON=false
(the bash functions) and with Python, in two directories. Compared:
wmbusmeters.conf, every meter file, status_mbus.json, the events file, the
log lines, the return code and the shell variables bash keeps afterwards
(alias, poll default, meter counts, exclude patterns by name).
"""
from __future__ import annotations

import json
import re
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
PORT = "PORT"  # replaced by an existing file: a port without a serial number

METERS = [
    {"id": "water", "address": "p1", "type": "auto"},
    {"id": "zero", "address": "p0"},
    {"id": "high", "address": "p251"},
    {"id": "sec", "address": "12345678", "type": "kamheat", "key": "00112233445566778899AABBCCDDEEFF",
     "poll_interval": "30s", "exclude_fields": "a_*,b", "calculated_fields": " total_l = total_m3 * 1000 ;bad name=1; x=;=y;noeq",
     "static_fields": "apartment = 12 b; floor=3;"},
    {"id": "badkey", "address": "p2", "key": "1234"},
    {"id": "other", "address": "p3", "type": "other"},
    {"id": "other2", "address": "p4", "type": "other", "type_other": "mydriver", "poll_interval": "15"},
    {"id": "", "address": "p5", "type": None},
    {"id": "with space", "address": "p250", "exclude_fields": "", "calculated_fields": "nl=a\nb"},
    {"id": 7, "address": "p6", "poll_interval": "1h", "static_fields": None},
]


class MbusConfigTests(unittest.TestCase):
    maxDiff = None

    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_side(self, side, options, loglevel="normal"):
        d = os.path.join(self.tmp, side)
        os.makedirs(d)
        port = os.path.join(d, "ttyFAKE")
        Path(port).write_text("")
        if options is not None:
            text = json.dumps(options).replace(PORT, port)
            Path(d, "options.json").write_text(text)
        clock = os.path.join(d, "clock")
        os.makedirs(clock)
        Path(clock, "sitecustomize.py").write_text("import time\ntime.time = lambda: float(%d)\n" % NOW)
        script = "\n".join([
            "set -uo pipefail",
            *(f"source '{p}'" for p in sorted(LIB_DIR.glob("*.sh"))),
            f"BASE='{d}'", f"RUNTIME='{d}'", f"OPTIONS_JSON='{d}/options.json'",
            f"STATUS_EVENTS_FILE='{d}/events.tsv'", f"MBUS_CONSUMER='{BIN}/wmbus_mbus.py'",
            f"LOGLEVEL={loglevel}", "mbus_init_paths",
            "MBUS_BUS_ALIAS=OLD", "MBUS_METERS_OK=7", "MBUS_METERS_SKIPPED=2",
            "MBUS_EXCLUDE_BY_NAME[stale]='kept'", "MBUS_EXCLUDE_BY_NAME[water]='dropped'",
            f"epoch_now() {{ echo {NOW}; }}", "iso_now() { echo 2026-10-02T10:00:00+00:00; }",
            "mkdir -p \"${MBUS_METER_DIR}\"; echo old > \"${MBUS_METER_DIR}/meter-0099\"",
            f"MBUS_CONFIG_IN_PYTHON={'false' if side == 'bash' else 'true'}",
            "_mbus_configure > \"$BASE/log\" 2>&1; rc=$?",
            "{ echo \"rc=$rc alias=$MBUS_BUS_ALIAS poll=$MBUS_POLL_DEFAULT ok=$MBUS_METERS_OK "
            "skipped=$MBUS_METERS_SKIPPED\"; for k in \"${!MBUS_EXCLUDE_BY_NAME[@]}\"; do "
            "printf 'exclude [%s]=[%s]\\n' \"$k\" \"${MBUS_EXCLUDE_BY_NAME[$k]}\"; done | sort; } > \"$BASE/vars\"",
        ])
        subprocess.run(["bash", "-c", script], check=True, timeout=60,
                       env=dict(os.environ, PYTHONPATH=clock, TZ="UTC"))
        out = {}
        for root, _, files in os.walk(d):
            for name in files:
                rel = os.path.relpath(os.path.join(root, name), d)
                if rel.startswith("clock") or rel == "options.json" or rel == "ttyFAKE":
                    continue
                text = Path(root, name).read_text().replace(d, "D")
                if rel == "log":
                    # An empty meter name is a bad subscript for bash's
                    # associative array on both paths (it was before);
                    # only the line and variable named in the message differ.
                    text = sorted(re.sub(r"^.*: line [0-9]+: (unset: )?\[.*\]: bad array subscript$",
                                         "BAD_ARRAY_SUBSCRIPT", ln) for ln in text.splitlines())
                if rel.endswith("status_mbus.json"):
                    text = json.loads(text)
                out[rel] = text
        return out

    def compare(self, options, loglevel="normal"):
        b = self.run_side("bash", options, loglevel)
        p = self.run_side("py", options, loglevel)
        shutil.rmtree(self.tmp)
        os.makedirs(self.tmp)
        self.assertEqual(p, b)
        return p

    def base(self, **kw):
        o = {"mbus_enabled": True, "mbus_device": PORT, "mbus_meters": METERS}
        o.update(kw)
        return o

    def test_meters(self):
        out = self.compare(self.base())
        conf = out["mbus/etc/wmbusmeters.conf"]
        self.assertIn("device=MAIN=D/ttyFAKE:mbus:2400\n", conf)
        files = [k for k in out if "/wmbusmeters.d/meter-" in k]
        self.assertGreaterEqual(len(files), 5)
        self.assertIn("calculate_total_l=total_m3 * 1000", "".join(out[k] for k in files))

    def test_variants(self):
        cases = {
            "no_device": self.base(mbus_device=""),
            "null_device": self.base(mbus_device=None),
            "missing_device": self.base(mbus_device="/dev/ttyNOPE"),
            "bad_alias": self.base(mbus_bus_alias="bus-1", mbus_poll_interval="15"),
            "flags": self.base(mbus_donotprobe_all=False, mbus_logtelegrams=True, mbus_ignoreduplicates=True,
                               mbus_baudrate=9600, mbus_loglevel="debug", mbus_bus_alias="B2"),
            "no_meters": self.base(mbus_meters=[]),
            "meters_missing": {"mbus_enabled": True, "mbus_device": PORT},
            "meters_object": self.base(mbus_meters={"a": {"id": "x", "address": "p9"}}),
            "poll_default": self.base(mbus_poll_interval="2h"),
        }
        for name, options in cases.items():
            with self.subTest(name):
                self.compare(options)
        with self.subTest("verbose"):
            self.compare(self.base(), loglevel="verbose")
        with self.subTest("no_options_file"):
            self.compare(None)


class IdentityTests(unittest.TestCase):
    """mbus_identity_check through a fake /sys (bash reads the real one, so
    these paths are checked against the bash function's rules, not run)."""

    def test_identity(self):
        import argparse
        import io
        import sys
        sys.path.insert(0, str(BIN))
        import wmbus_mbus as wm
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        dev = os.path.join(d, "dev", "ttyUSB7")
        os.makedirs(os.path.dirname(dev))
        Path(dev).write_text("")
        usb = os.path.join(d, "sys", "devices", "usb1")
        os.makedirs(os.path.join(usb, "tty"))
        Path(usb, "serial").write_text("A50285BI\n")
        os.makedirs(os.path.join(d, "sys", "class", "tty", "ttyUSB7"))
        os.symlink(os.path.join(usb, "tty"), os.path.join(d, "sys", "class", "tty", "ttyUSB7", "device"))
        old = wm.SYS_ROOT
        wm.SYS_ROOT = os.path.join(d, "sys")
        self.addCleanup(setattr, wm, "SYS_ROOT", old)
        a = argparse.Namespace(options=os.path.join(d, "options.json"), conf=os.path.join(d, "conf"),
                               meter_dir=os.path.join(d, "meters"), status_file=os.path.join(d, "status.json"),
                               events_file=os.path.join(d, "events"), alias="MAIN", configured="0",
                               skipped="0", loglevel="")
        for pinned, want, rc in (("A50285BI", "ok", "0"), ("", "unknown_identity", "0"),
                                 ("OTHER", "changed", "1")):
            with self.subTest(pinned=pinned):
                if os.path.exists(a.conf):
                    os.unlink(a.conf)
                Path(a.options).write_text(json.dumps({"mbus_device": dev, "mbus_device_serial": pinned,
                                                       "mbus_meters": []}))
                out, err = io.StringIO(), io.StringIO()
                cfg = wm.MbusConfig(a, out=out, err=err)
                self.assertEqual(cfg.identity(dev, pinned), want)
                cfg.run()
                self.assertTrue(out.getvalue().endswith(f"rc{wm.SEP}{rc}\n"), out.getvalue())
                if want == "changed":
                    self.assertEqual(json.loads(Path(a.status_file).read_text())["state"], "identity_changed")
                    self.assertIn("M-Bus device identity changed on", Path(a.events_file).read_text())
                    self.assertIn("is now a different device", err.getvalue())
                    self.assertFalse(os.path.exists(a.conf))


if __name__ == "__main__":
    unittest.main()
