#!/usr/bin/env python3
"""Meters on an external_* driver never reach the main wmbusmeters.

wmbusmeters ends on a meter whose driver it does not know (rc 5, measured on
3.1.1), so such a meter in the main meter directory would stop every meter.
wmbus_meters.py refresh writes it to the external instance's directory, and
only when custom drivers are on and that driver passed custom_drivers.py.
"""

import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "rootfs" / "usr" / "bin"))

import bridge_ledger as bl  # noqa: E402
import wmbus_meters as wm  # noqa: E402

METERS = [
    {"id": "water", "meter_id": "03264950", "type": "hydrodigit"},
    {"id": "ext", "meter_id": "12345678", "type": "other", "type_other": "external_mine"},
    {"id": "bad", "meter_id": "12345679", "type": "other", "type_other": "external_broken"},
    {"id": "missing", "meter_id": "12345680", "type": "other", "type_other": "external_nowhere"},
    {"id": "heat", "meter_id": "03534159", "type": "kamheat"},
]

STATUS_ON = {"enabled": True, "checked_at": 1, "drivers": [
    {"file": "external_mine.xmq", "name": "external_mine", "ok": True, "reason": ""},
    {"file": "external_broken.xmq", "name": "external_broken", "ok": False, "reason": "crashed"},
]}


class ExternalMeters(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = Path(self.tmp.name)
        self.main = d / "etc" / "wmbusmeters.d"
        self.ext = d / "external" / "etc" / "wmbusmeters.d"
        self.main.mkdir(parents=True)
        self.ext.mkdir(parents=True)
        (self.main / "meter-0042").write_text("stale\n")
        (self.ext / "meter-0007").write_text("stale\n")
        self.options = d / "options.json"
        self.options.write_text(json.dumps({"meters": METERS}))
        self.status = d / "status_custom_drivers.json"

    def tearDown(self):
        self.tmp.cleanup()

    def refresh(self, status=None):
        if status is not None:
            self.status.write_text(json.dumps(status))
        out, err = io.StringIO(), io.StringIO()
        ap_args = ["refresh", f"--options={self.options}", f"--meter-dir={self.main}",
                   "--search-candidates-file=", f"--external-meter-dir={self.ext}",
                   f"--external-drivers-status={self.status}", "--loglevel=normal"]
        with mock.patch.object(sys, "stdout", out), mock.patch.object(sys, "stderr", err):
            self.assertEqual(wm.main(ap_args), 0)
        sets = dict(ln.split("\x1f")[1:3] for ln in out.getvalue().splitlines() if ln.startswith("set\x1f"))
        return sets, err.getvalue()

    def ids(self, d):
        found = {}
        for p in sorted(d.glob("meter-*")):
            lines = p.read_text().splitlines()
            found[next(ln[3:] for ln in lines if ln.startswith("id="))] = \
                next((ln[7:] for ln in lines if ln.startswith("driver=")), "auto")
        return found

    def test_accepted_driver_goes_to_the_external_instance_only(self):
        sets, err = self.refresh(STATUS_ON)
        self.assertEqual(self.ids(self.main), {"03264950": "hydrodigit", "03534159": "kamheat"})
        self.assertEqual(self.ids(self.ext), {"12345678": "external_mine"})
        self.assertEqual(sorted(p.name for p in self.main.glob("meter-*")), ["meter-0001", "meter-0002"])
        self.assertEqual(sets["OFFICIAL_METERS_COUNT"], "3")
        self.assertEqual(sets["EXTERNAL_METERS_COUNT"], "1")
        self.assertIn("external_broken, but the driver did not pass the check (crashed)", err)
        self.assertIn("external_nowhere, but no such driver was uploaded", err)

    def test_option_off_or_no_status_skips_every_external_meter(self):
        for status in ({"enabled": False, "drivers": STATUS_ON["drivers"]}, None, "garbage"):
            with self.subTest(status=status):
                if status is None:
                    self.status.unlink(missing_ok=True)
                    sets, err = self.refresh()
                elif status == "garbage":
                    self.status.write_text("{not json")
                    sets, err = self.refresh()
                else:
                    sets, err = self.refresh(status)
                self.assertEqual(self.ids(self.ext), {})
                self.assertNotIn("external_", "".join(p.read_text() for p in self.main.glob("meter-*")))
                self.assertEqual(sets["EXTERNAL_METERS_COUNT"], "0")
                self.assertIn("custom drivers are off", err)

    def test_external_meter_counts_as_configured_for_the_ledger(self):
        self.refresh(STATUS_ON)
        with mock.patch.dict(os.environ, {"EXTERNAL_METER_DIR": str(self.ext)}):
            self.assertTrue(bl.official_meter(str(self.main), "12345678"))
            self.assertIn("12345678", bl.meter_ids_in(str(self.main)))
        with mock.patch.dict(os.environ, {"EXTERNAL_METER_DIR": ""}):
            self.assertFalse(bl.official_meter(str(self.main), "12345678"))


if __name__ == "__main__":
    unittest.main()
