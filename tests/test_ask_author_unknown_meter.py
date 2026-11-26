#!/usr/bin/env python3
"""A meter no driver knows: ask the add-on author first.

A missing driver is not a bug, neither in the add-on nor (yet) in
wmbusmeters, so the report of a candidate wmbusmeters names no driver for
marks itself undecoded and carries the frame's manufacturer, version and
type. The WebUI then opens the question in the "Unknown meters" discussion
category, titled with the model, with the checklist and the guide linked.
A configured meter keeps the Q&A question.
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
sys.path.insert(0, str(BIN))

_TMP = tempfile.TemporaryDirectory()
BASE = Path(_TMP.name)
os.environ["WMBUS_BASE"] = str(BASE)
SPEC = importlib.util.spec_from_file_location("wmbus_webui_ask_author", BIN / "webui.py")
webui = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(webui)

# A Hydroclima 0x34 long frame (id 51736092 sent as 92607351), BMP,34,08.
RAW = "2d44b009" + "92607351" + "3408780fbd130000E54B53F453EB8CE4C0EAFCE297EC30EB8AEC8AEC30EB30EB30EB11EB30E3"
MID = "51736092"


class AskAuthor(unittest.TestCase):
    def setUp(self):
        webui.RUNTIME.mkdir(parents=True, exist_ok=True)
        stub = BASE / "wmbusmeters"
        stub.write_text("#!/bin/sh\necho 'Auto driver    : unknown!'\n", encoding="utf-8")
        stub.chmod(0o755)
        webui.WMBUSMETERS_BIN = str(stub)
        (BASE / "status_recent_raw.tsv").write_text(f"2026-11-26T06:00:00Z\t{len(RAW)}\t{RAW}\n", encoding="utf-8")
        webui.OPTIONS_JSON.write_text(json.dumps({"meters": []}), encoding="utf-8")

    def test_model_from_the_frame(self):
        self.assertEqual(webui._frame_mvt(RAW), "BMP,34,08")
        self.assertEqual(webui._frame_mvt("2d44"), "")
        self.assertEqual(webui._frame_mvt("zz" * 12), "")

    def test_unknown_candidate_is_undecoded(self):
        ok, payload = webui.candidate_issue_report(MID)
        self.assertTrue(ok, payload)
        self.assertTrue(payload["undecoded"])
        self.assertEqual(payload["mvt"], "BMP,34,08")

    def test_configured_meter_is_not(self):
        webui.OPTIONS_JSON.write_text(json.dumps({"meters": [
            {"id": "Hydro", "meter_id": MID, "type": "other", "type_other": "vendor_bmeters_hydroclima_v34"}]}),
            encoding="utf-8")
        ok, payload = webui.candidate_issue_report(MID)
        self.assertTrue(ok, payload)
        self.assertFalse(payload["undecoded"])

    def test_webui_opens_the_unknown_meters_category(self):
        js = APP_JS.read_text(encoding="utf-8")
        self.assertIn('rm.undecoded ? "nowe-liczniki-unknown-meters" : "q-a"', js)
        self.assertIn("Unknown meter ${rm.mvt", js)
        self.assertIn("docs/UNKNOWN_METER.md", js)
        self.assertTrue((ROOT / "docs" / "UNKNOWN_METER.md").is_file())
        self.assertTrue((ROOT / "docs" / "UNKNOWN_METER.pl.md").is_file())


if __name__ == "__main__":
    unittest.main()
