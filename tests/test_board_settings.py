#!/usr/bin/env python3
"""Board settings: <board>/diag/settings kept per board (esp_books) and the
command the Boards tab sends through the persistent MQTT publisher."""

import importlib.util
import json
import os
import socket
import sys
import tempfile
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "rootfs" / "usr" / "bin"
sys.path.insert(0, str(BIN))

import esp_books  # noqa: E402

_TMP = tempfile.TemporaryDirectory()
BASE = Path(_TMP.name)
os.environ["WMBUS_BASE"] = str(BASE)
SPEC = importlib.util.spec_from_file_location("wmbus_webui_board_settings", BIN / "webui.py")
webui = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(webui)

SETTINGS = {"v": 1, "radio": "CC1101", "listen_mode": {
    "value": "both", "source": "yaml", "yaml": "both", "options": ["t1", "c1", "both", "s1"],
    "unsupported": ["s1"], "weak": [], "apply": "restart"}}


class Store(unittest.TestCase):
    def test_settings_are_kept_per_board_and_not_logged(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            book = esp_books.DiagEventsBook(str(p / "events"), str(p / "sugg"), str(p / "boot"),
                                            str(p / "config"), settings_file=str(p / "settings"))
            book(b"1", b"wmbus/cc1101/diag/settings", json.dumps(SETTINGS).encode())
            book(b"0", b"wmbus/xiaoseed/diag/settings", json.dumps(SETTINGS).encode())
            got = json.loads((p / "settings").read_text())
            self.assertEqual(sorted(got), ["cc1101", "xiaoseed"])
            self.assertEqual(got["cc1101"]["listen_mode"]["value"], "both")
            self.assertFalse((p / "events").exists() and (p / "events").read_text().strip())


class Send(unittest.TestCase):
    def setUp(self):
        webui.STATUS_ESP_SETTINGS_FILE.write_text(json.dumps({"cc1101": SETTINGS}))
        self.addCleanup(webui.STATUS_ESP_SETTINGS_FILE.unlink)

    def test_validation(self):
        self.assertEqual(webui.board_setting_send("bad name", "listen_mode", "c1")[1], "invalid board")
        self.assertEqual(webui.board_setting_send("cc1101", "frequency", "868")[1], "invalid setting")
        self.assertEqual(webui.board_setting_send("cc1101", "listen_mode", "x1")[1], "invalid setting")
        self.assertIn("not supported", webui.board_setting_send("cc1101", "listen_mode", "s1")[1])
        self.assertIn("does not take", webui.board_setting_send("heltec", "listen_mode", "c1")[1])

    def test_publishes_through_the_publisher(self):
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        got = []

        def accept():
            conn, _ = srv.accept()
            data = b""
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
            got.append(data)
            conn.close()

        t = threading.Thread(target=accept)
        t.start()
        port_file = webui.RUNTIME / "mqtt_publisher.port"
        port_file.write_text(f"{srv.getsockname()[1]} dec books\n")
        self.addCleanup(port_file.unlink)
        ok, msg = webui.board_setting_send("cc1101", "listen_mode", "C1")
        t.join(5)
        srv.close()
        self.assertTrue(ok, msg)
        self.assertEqual(got, [b"PUB 0 2 wmbus/cc1101/set/listen_mode\nc1\n"])

    def test_every_tile_text_exists_in_five_languages(self):
        import re
        js = (ROOT / "rootfs" / "usr" / "share" / "wmbus-webui" / "assets" / "app.js").read_text(encoding="utf-8")
        keys = set(re.findall(r'\bt\("((?:bs_|diag_section)[a-z_0-9]*)"', js))
        self.assertIn("bs_no_settings", keys)
        for lang in ("en", "pl", "de", "cs", "sk"):
            missing = sorted(k for k in keys if k not in webui.I18N[lang])
            self.assertEqual(missing, [], lang)


if __name__ == "__main__":
    unittest.main()
