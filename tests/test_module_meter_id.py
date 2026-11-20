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
must give the configured address back from the telegram's name (the meter file
wmbusmeters matched), also when both numbers are configured, and leave the id
alone when the name is ambiguous or missing.
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

    def test_both_numbers_configured_each_meter_gets_its_own(self):
        both = {METER_ID: "water", MODULE_ID: "myname"}
        self.assertEqual(self.f(METER_ID, "myname", both), MODULE_ID)
        self.assertEqual(self.f(METER_ID, "water", both), METER_ID)

    def test_ordinary_meter_keeps_its_id(self):
        self.assertEqual(self.f("03534161", "kitchen", {"03534161": "kitchen", MODULE_ID: "myname"}), "03534161")

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
            ({METER_ID: "water", MODULE_ID: "myname"}, METER_ID, "myname"),
            ({METER_ID: "water", MODULE_ID: "myname"}, METER_ID, "water"),
            ({"03534161": "kitchen", MODULE_ID: "myname"}, "03534161", "kitchen"),
            ({MODULE_ID: "meter", "11111111": "meter"}, METER_ID, "meter"),
            ({MODULE_ID: "myname"}, METER_ID, ""),
            ({}, METER_ID, "myname"),
        ]
        for mapping, mid, name in cases:
            with self.subTest(mapping=mapping, name=name):
                self.assertEqual(self.run_bash(mapping, mid, name),
                                 bridge_ledger.configured_meter_id(mid, name, mapping))


class PreviewTest(unittest.TestCase):
    """The candidate list's preview decodes one candidate (the module's address)
    and must book the value under it, not under the reported meter number."""

    def test_python_sets_the_candidate_id(self):
        out = bridge_ledger.preview_json_for(MODULE_ID, FAW_JSON)
        self.assertIn(f'"id":"{MODULE_ID}"', out)
        self.assertNotIn(METER_ID, out)
        self.assertIn('"consumption_at_reporting_date_m3":59.682', out)

    def test_python_leaves_a_matching_id(self):
        self.assertEqual(bridge_ledger.preview_json_for(METER_ID, FAW_JSON), FAW_JSON)

    def test_bash_gives_the_same_line(self):
        src = (ROOT / "rootfs" / "usr" / "bin" / "bridge-lib" / "06-candidates.sh").read_text(encoding="utf-8")
        line = next((ln for ln in src.splitlines()
                     if ln.strip().startswith('json_line="$(printf') and 'sed -E \'s/"id":' in ln), "")
        assert line, "preview id rewrite not found in 06-candidates.sh"
        sed = line.split("| ", 1)[1].rsplit(')"', 1)[0]
        script = f"id={MODULE_ID}\njson_line='{FAW_JSON}'\nprintf '%s' \"$json_line\" | {sed}"
        out = subprocess.run(["bash", "-c", script], capture_output=True, text=True, check=True).stdout
        self.assertEqual(out, bridge_ledger.preview_json_for(MODULE_ID, FAW_JSON))


class ListenPreviewTest(unittest.TestCase):
    """The LISTEN instance decodes candidates with their preview configs too
    (name=preview_<id>); its JSON must also be booked under the candidate."""
    LINE = FAW_JSON.replace('"name":"myname"', f'"name":"preview_{MODULE_ID}"')

    def test_python(self):
        out = bridge_ledger.preview_json_by_name(self.LINE)
        self.assertIn(f'"id":"{MODULE_ID}"', out)
        self.assertEqual(bridge_ledger.preview_json_by_name(FAW_JSON), FAW_JSON)  # not a preview name

    def test_bash_same(self):
        src = (ROOT / "rootfs" / "usr" / "bin" / "bridge-lib" / "11-listen.sh").read_text(encoding="utf-8")
        lines = src.splitlines()
        start = lines.index("_process_listen_json_line() {")
        # The function's head: from the declaration to the end of the preview block.
        end = next(i for i in range(start, len(lines)) if lines[i] == "  fi")
        body = "\n".join(lines[start + 1:end + 1]).replace('local line="$1" _pid', "local _pid")
        script = "f() {\n" + f"line='{self.LINE}'\n" + body + "\nprintf '%s' \"$line\"\n}\nf"
        out = subprocess.run(["bash", "-c", script], capture_output=True, text=True, check=True).stdout
        self.assertEqual(out, bridge_ledger.preview_json_by_name(self.LINE))


class AliasNoteTest(unittest.TestCase):
    """The reported meter number is kept next to the shown id for the WebUI."""

    def test_written_only_when_numbers_differ(self):
        import tempfile, os
        with tempfile.TemporaryDirectory() as d:
            near = os.path.join(d, "status_meters.tsv")
            bridge_ledger.note_reported_id(near, MODULE_ID, METER_ID)
            bridge_ledger.note_reported_id(near, "03534161", "03534161")
            rows = Path(d, bridge_ledger.ALIASES_NAME).read_text().splitlines()
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0].split("	")[:2], [MODULE_ID, METER_ID])

    def test_json_id(self):
        self.assertEqual(bridge_ledger.json_id(FAW_JSON), METER_ID)


class GhostCandidateTest(unittest.TestCase):
    """Older versions registered the reported meter number as a candidate of
    its own (from the decoded JSON); that row is hidden next to the module."""

    def setUp(self):
        import os, tempfile
        os.environ.setdefault("WMBUS_BASE", tempfile.mkdtemp())
        import webui
        self.f = webui.module_meter_ghost_ids

    def test_json_only_row_of_the_reported_number_is_a_ghost(self):
        cands = [{"id": MODULE_ID, "manufacturer": "EFE", "reported_id": METER_ID},
                 {"id": METER_ID, "manufacturer": ""}]
        self.assertEqual(self.f(cands, [], []), {METER_ID})

    def test_reported_by_a_configured_meter(self):
        self.assertEqual(self.f([{"id": METER_ID}], [{"id": MODULE_ID, "reported_id": METER_ID}], []),
                         {METER_ID})

    def test_a_sender_of_its_own_stays(self):
        cands = [{"id": MODULE_ID, "reported_id": METER_ID},
                 {"id": METER_ID, "manufacturer": "EFE"}]
        self.assertEqual(self.f(cands, [], []), set())

    def test_nothing_reported_nothing_hidden(self):
        self.assertEqual(self.f([{"id": METER_ID}, {"id": MODULE_ID}], [], []), set())


if __name__ == "__main__":
    unittest.main()
