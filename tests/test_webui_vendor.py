#!/usr/bin/env python3
"""The WebUI and vendor formats (vendor_formats.py).

A candidate wmbusmeters cannot decode, whose frames match a vendor format,
must come with that format's driver (so adding it does not start from auto)
and its value; the driver picker must offer the formats; a comparison with a
vendor driver must decode, a short frame with the help of a stored long one.
A format wmbusmeters already decodes is offered nowhere.
"""

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "rootfs" / "usr" / "bin"
APP_JS = ROOT / "rootfs" / "usr" / "share" / "wmbus-webui" / "assets" / "app.js"
FORMATS = ROOT / "rootfs" / "usr" / "share" / "wmbus-bridge" / "formats"
sys.path.insert(0, str(BIN))

_TMP = tempfile.TemporaryDirectory()
BASE = Path(_TMP.name)
os.environ["WMBUS_BASE"] = str(BASE)
os.environ["VENDOR_FORMATS_DIR"] = str(FORMATS)
SPEC = importlib.util.spec_from_file_location("wmbus_webui_vendor", BIN / "webui.py")
webui = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(webui)

HC = json.loads((FORMATS / "bmeters_hydroclima_v34.json").read_text(encoding="utf-8"))
LONG = HC["tests"][0]["telegram"]
SHORT = HC["tests"][1]["telegram"]


class VendorInWebUI(unittest.TestCase):
    def setUp(self):
        webui.RUNTIME.mkdir(parents=True, exist_ok=True)
        rows = [("78240400", "2026-11-20T13:27:11Z", LONG), ("78240400", "2026-11-20T13:27:17Z", SHORT)]
        webui.CANDIDATE_RAW_TSV.write_text(
            "".join(f"{i}\t{ts}\t{len(r) // 2}\t{r}\n" for i, ts, r in rows), encoding="utf-8")
        self.status(upstream="")

    def status(self, upstream="", ok=True):
        webui.STATUS_VENDOR_FORMATS_FILE.write_text(json.dumps({"checked_at": 1, "formats": [
            {"name": HC["name"], "ok": ok, "reason": "", "upstream_driver": upstream}]}), encoding="utf-8")
        webui._VENDOR_CACHE["key"] = None

    def test_candidate_gets_the_vendor_driver_and_its_value(self):
        cands = [{"id": "78240400", "driver": "unknown"}, {"id": "03264950", "driver": "hydrodigit"}]
        webui.apply_vendor_hints(cands)
        hc, water = cands
        self.assertEqual(hc["driver"], "vendor_bmeters_hydroclima_v34")
        self.assertEqual(hc["preview_value_key"], "allocation_hca")
        self.assertEqual(hc["preview_value"], "51.7")
        self.assertEqual(water["driver"], "hydrodigit")  # a driver wmbusmeters has is never replaced

    def test_no_hint_when_wmbusmeters_knows_the_format_or_it_failed(self):
        for kwargs in ({"upstream": "hydroclima"}, {"ok": False}):
            self.status(**kwargs)
            cands = [{"id": "78240400", "driver": "unknown"}]
            webui.apply_vendor_hints(cands)
            self.assertEqual(cands[0]["driver"], "unknown")
            self.assertEqual(webui.vendor_format_drivers(), [])

    def test_picker_list(self):
        self.assertEqual([d["driver"] for d in webui.vendor_format_drivers()], ["vendor_bmeters_hydroclima_v34"])
        js = APP_JS.read_text(encoding="utf-8")
        self.assertIn("state.data?.vendor_formats", js)

    def test_compare_decodes_with_a_vendor_driver(self):
        long_fields = webui._decode_with_driver(LONG, "vendor_bmeters_hydroclima_v34", "78240400", "")
        self.assertEqual(long_fields["allocation_hca"], 51.7)
        # the short frame alone has no constant word; the stored long frame supplies it
        short_fields = webui._decode_with_driver(SHORT, "vendor_bmeters_hydroclima_v34", "78240400", "")
        self.assertEqual(short_fields["previous_month_10_hca"], 23.6)
        self.assertIsNone(webui._decode_with_driver(LONG, "vendor_no_such_format", "78240400", ""))

    def test_editor_fields_of_a_vendor_driver(self):
        # 1.6.25 asked wmbusmeters --listfields, which does not know the
        # driver: the editor showed "No such driver" and no field to pick.
        ok, fields, err = webui.driver_fields("vendor_bmeters_hydroclima_v34")
        self.assertTrue(ok, err)
        names = [f["name"] for f in fields]
        self.assertIn("allocation_hca", names)
        self.assertIn("previous_month_10_hca", names)  # short-frame history too
        self.assertEqual(len(names), len(set(names)))
        self.assertFalse(webui.driver_fields("vendor_no_such_format")[0])


if __name__ == "__main__":
    unittest.main()
