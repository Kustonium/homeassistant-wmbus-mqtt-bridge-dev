"""A meter read through a radio module (issue 182, Engelmann FAW on a water meter).

The module transmits with its own address in the link layer; the user
configures that address. wmbusmeters decodes the telegram and reports the
water meter's own number as JSON "id" (from the long application header), so
the decoded telegram never matched the configured meter: it stayed under
"Waiting for first telegram" although its values reached Home Assistant.

Real frame from wmbusmeters' own engelmann_faw test: link-layer address
43000255 (55020043), application-header id 20254060 (60402520), and
wmbusmeters reports "id":"20254060".

configured_meter_id (bridge_ledger.py) and meter_configured_id (07-meters.sh)
must give the configured address back from the telegram's name, and nothing
else: not when the id is configured itself, not when the name is ambiguous.
"""
from __future__ import annotations

import re
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "rootfs" / "usr" / "bin"))

import bridge_ledger  # noqa: E402

FAW_TELEGRAM = (
    "8f44c5145502004301077260402520c51400076b0000002f2f426cbf2c441322e9000001fd17008401133c340100"
)
FAW_JSON = ('{"_":"telegram","media":"water","driver":"engelmann_faw","name":"myname",'
            '"id":"20254060","status":"OK","consumption_at_reporting_date_m3":59.682}')
MODULE_ID = "43000255"   # what the user configures (link layer)
METER_ID = "20254060"    # what wmbusmeters reports as "id"


class FrameTest(unittest.TestCase):
    def test_fixture_is_the_module_case(self):
        # Link-layer address bytes 4..7 little-endian, application header id 11..14.
        b = bytes.fromhex(FAW_TELEGRAM)
        self.assertEqual(b[4:8][::-1].hex(), MODULE_ID)
        self.assertEqual(b[11:15][::-1].hex(), METER_ID)
        self.assertIn(f'"id":"{METER_ID}"', FAW_JSON)


class PythonTest(unittest.TestCase):
    f = staticmethod(bridge_ledger.configured_meter_id)

    def test_module_meter_resolves_to_the_configured_address(self):
        self.assertEqual(self.f(METER_ID, "myname", {MODULE_ID: "myname"}), MODULE_ID)

    def test_configured_id_wins(self):
        self.assertEqual(self.f(METER_ID, "myname", {METER_ID.lower(): "other", MODULE_ID: "myname"}), METER_ID)

    def test_ambiguous_name_changes_nothing(self):
        self.assertEqual(self.f(METER_ID, "meter", {MODULE_ID: "meter", "11111111": "meter"}), METER_ID)

    def test_no_name_or_no_map_changes_nothing(self):
        self.assertEqual(self.f(METER_ID, "", {MODULE_ID: "myname"}), METER_ID)
        self.assertEqual(self.f(METER_ID, "myname", {}), METER_ID)

    def test_metadata_of_the_real_json(self):
        raw_id, name, meter, media = bridge_ledger.meter_metadata(FAW_JSON)
        mid = bridge_ledger.normalize_id(raw_id)
        self.assertEqual(bridge_ledger.configured_meter_id(mid, name, {MODULE_ID: "myname"}), MODULE_ID)


def _bash_function() -> str:
    src = (ROOT / "rootfs" / "usr" / "bin" / "bridge-lib" / "07-meters.sh").read_text(encoding="utf-8")
    m = re.search(r"^meter_configured_id\(\) \{.*?^\}", src, re.S | re.M)
    assert m, "meter_configured_id not found in 07-meters.sh"
    return m.group(0)


class BashTest(unittest.TestCase):
    """The bash decode path (LEDGER_DECODE_IN_PYTHON=false) gives the same."""

    def run_bash(self, mapping: dict, mid: str, name: str) -> str:
        decl = " ".join(f'["{k}"]="{v}"' for k, v in mapping.items())
        script = f'declare -A METER_NAME_BY_ID=({decl})\n{_bash_function()}\nmeter_configured_id "{mid}" "{name}"'
        return subprocess.run(["bash", "-c", script], capture_output=True, text=True, check=True).stdout

    def test_same_answers_as_python(self):
        cases = [
            ({MODULE_ID: "myname"}, METER_ID, "myname"),
            ({METER_ID: "other", MODULE_ID: "myname"}, METER_ID, "myname"),
            ({MODULE_ID: "meter", "11111111": "meter"}, METER_ID, "meter"),
            ({MODULE_ID: "myname"}, METER_ID, ""),
            ({}, METER_ID, "myname"),
        ]
        for mapping, mid, name in cases:
            with self.subTest(mapping=mapping, name=name):
                self.assertEqual(self.run_bash(mapping, mid, name),
                                 bridge_ledger.configured_meter_id(mid, name, mapping))


if __name__ == "__main__":
    unittest.main()
