#!/usr/bin/env python3
"""The Drivers tab: upload, removal and Compare for external .xmq drivers.

A fake wmbusmeters (the one of test_custom_drivers.py) stands in for the
real one, so a file is accepted, rejected or crashes on purpose.
"""

import importlib.util
import json
import os
import re
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "rootfs" / "usr" / "bin"
APP_JS = ROOT / "rootfs" / "usr" / "share" / "wmbus-webui" / "assets" / "app.js"
sys.path.insert(0, str(BIN))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_custom_drivers import FAKE, driver  # noqa: E402

_TMP = tempfile.TemporaryDirectory()
BASE = Path(_TMP.name)
os.environ["WMBUS_BASE"] = str(BASE)
os.environ.pop("CUSTOM_DRIVERS_DIR", None)
os.environ.pop("CUSTOM_DRIVERS_NDA_DIR", None)
SPEC = importlib.util.spec_from_file_location("wmbus_webui_drivers", BIN / "webui.py")
webui = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(webui)


class Drivers(unittest.TestCase):
    def setUp(self):
        fake = BASE / "wmbusmeters"
        fake.write_text(FAKE, encoding="utf-8")
        fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
        os.environ["WMBUSMETERS_BIN"] = str(fake)
        for d in (webui.CUSTOM_DRIVERS_DIR, webui.CUSTOM_DRIVERS_NDA_DIR, webui.EXT_DRIVERS_DIR):
            d.mkdir(parents=True, exist_ok=True)
            for f in d.iterdir():
                f.unlink()
        self.options({"custom_drivers_enabled": True,
                      "meters": [{"id": "Ext", "meter_id": "03264950", "type": "external_good"},
                                 {"id": "Gone", "meter_id": "11111111", "type": "other",
                                  "type_other": "external_gone"}]})

    def options(self, opts):
        (BASE / "options.json").write_text(json.dumps(opts), encoding="utf-8")

    def test_upload_defaults_to_nda_and_reaches_the_instance(self):
        ok, res = webui.drivers_upload(driver("external_good"), nda=True)
        self.assertTrue(ok, res)
        self.assertTrue((webui.CUSTOM_DRIVERS_NDA_DIR / "external_good.xmq").is_file())
        self.assertTrue((webui.EXT_DRIVERS_DIR / "external_good.xmq").is_file())
        payload = webui.drivers_payload()
        f = payload["files"][0]
        self.assertEqual((f["name"], f["nda"], f["ok"], f["meters"]),
                         ("external_good", True, True, ["Ext (03264950)"]))
        self.assertEqual(payload["missing"], {"external_gone": ["Gone (11111111)"]})
        self.assertEqual(webui.accepted_external_drivers(), ["external_good"])

    def test_not_nda_moves_the_file_out_of_the_nda_directory(self):
        webui.drivers_upload(driver("external_good"), nda=True)
        ok, _ = webui.drivers_upload(driver("external_good"), nda=False)
        self.assertTrue(ok)
        self.assertFalse((webui.CUSTOM_DRIVERS_NDA_DIR / "external_good.xmq").exists())
        self.assertTrue((webui.CUSTOM_DRIVERS_DIR / "external_good.xmq").is_file())

    def test_bad_files_are_refused_and_never_stored(self):
        cases = {"rejected": driver("external_bad", "BAD"), "crashed": driver("external_boom", "CRASH"),
                 "name_without_prefix": driver("kamwater"), "empty": "", "not_a_driver": "hello"}
        for reason, text in cases.items():
            with self.subTest(reason=reason):
                ok, res = webui.drivers_upload(text, nda=True)
                self.assertFalse(ok)
                self.assertEqual(res["reason"], reason)
        self.assertEqual(list(webui.CUSTOM_DRIVERS_NDA_DIR.iterdir()), [])
        self.assertEqual(list(webui.EXT_DRIVERS_DIR.iterdir()), [])

    def test_a_file_that_removes_an_uploaded_one_is_refused(self):
        webui.drivers_upload(driver("external_a"), nda=True)
        ok, res = webui.drivers_upload(driver("external_b", "REMOVES=external_a"), nda=True)
        self.assertFalse(ok)
        self.assertEqual(res["reason"], "conflict")

    def test_disabled_option_refuses_everything(self):
        self.options({"custom_drivers_enabled": False})
        ok, res = webui.drivers_upload(driver("external_good"), nda=True)
        self.assertEqual((ok, res["reason"]), (False, "disabled"))
        self.assertEqual(webui.accepted_external_drivers(), [])

    def test_delete(self):
        webui.drivers_upload(driver("external_good"), nda=False)
        self.assertEqual(webui.drivers_delete("../etc/passwd")[1]["reason"], "bad_name")
        self.assertEqual(webui.drivers_delete("external_none")[1]["reason"], "not_found")
        ok, _ = webui.drivers_delete("external_good")
        self.assertTrue(ok)
        self.assertEqual(list(webui.EXT_DRIVERS_DIR.iterdir()), [])

    def test_compare_loads_only_an_accepted_external_driver(self):
        with mock.patch.object(webui.subprocess, "run") as run:
            run.return_value = mock.Mock(stdout="", stderr="")
            self.assertIsNone(webui._decode_with_driver("aabb", "external_good", "03264950", ""))
            run.assert_not_called()
        self.assertTrue(webui.drivers_upload(driver("external_good"), nda=True)[0])
        with mock.patch.object(webui.subprocess, "run") as run:
            run.return_value = mock.Mock(stdout="", stderr="")
            webui._decode_with_driver("aabb", "external_good", "03264950", "")
            self.assertIn(f"--driversdir={webui.EXT_DRIVERS_DIR}", run.call_args[0][0])
            webui._decode_with_driver("aabb", "hydrodigit", "03264950", "")
            self.assertFalse(any(a.startswith("--driversdir") for a in run.call_args[0][0]))


class Texts(unittest.TestCase):
    def test_every_drivers_text_exists_in_five_languages(self):
        js = APP_JS.read_text(encoding="utf-8")
        keys = set(re.findall(r'\bt\("((?:xdrv|nav_drivers)[a-z_]*)"', js))
        keys |= {f"xdrv_reason_{r}" for r in (
            "empty", "too_large", "not_text", "not_a_driver", "no_name", "name_without_prefix",
            "bad_name", "name_is_builtin", "duplicate_name", "rejected", "crashed", "timeout",
            "wmbusmeters_missing", "wmbusmeters_unavailable", "not_loaded", "conflict", "disabled",
            "not_found")}
        self.assertIn("xdrv_responsibility", keys)
        for lang in ("en", "pl", "de", "cs", "sk"):
            missing = sorted(k for k in keys if k not in webui.I18N[lang])
            self.assertEqual(missing, [], lang)

    def test_live_render_keeps_the_chosen_file(self):
        js = APP_JS.read_text(encoding="utf-8")
        self.assertIn('from.tagName === "INPUT" && from.type === "file"', js)


if __name__ == "__main__":
    unittest.main()
