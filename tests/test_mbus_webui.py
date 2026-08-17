#!/usr/bin/env python3
"""Regression tests for the bounded wired M-Bus WebUI control plane."""

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


WEBUI = Path(__file__).parents[1] / "rootfs" / "usr" / "bin" / "webui.py"
sys.path.insert(0, str(WEBUI.parent))
SPEC = importlib.util.spec_from_file_location("wmbus_webui", WEBUI)
webui = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(webui)


class MBusWebUITest(unittest.TestCase):
    def test_frame_shapes(self):
        cases = {
            "e5": "ack",
            "10010116": "frame_short",
            "68030368010203": "frame_long",
            "68030468010203": "not_mbus",
            "7ea001": "not_mbus",
            "": "empty",
        }
        for frame, expected in cases.items():
            with self.subTest(frame=frame):
                self.assertEqual(webui.mbus_frame_shape(frame), expected)

    def test_console_classifies_decoder_signatures_and_raw_shapes(self):
        with tempfile.TemporaryDirectory() as directory:
            old_base = webui.BASE
            webui.BASE = Path(directory)
            try:
                log = webui.BASE / "mbus" / "console.log"
                log.parent.mkdir()
                log.write_text(
                    "(mbus) no 0x68 byte found, clearing buffer.\n"
                    "telegram=|68030368010203|\n"
                    "telegram=|7ea001|\n"
                    "(mbus) expected checksum 0x0a but got 0x50\n"
                    "(meter) sim p2 did not send a response!\n",
                    encoding="utf-8",
                )
                lines = webui.mbus_console_lines()
            finally:
                webui.BASE = old_base
        self.assertEqual(
            [(line["kind"], line["shape"]) for line in lines],
            [("not_mbus", ""), ("frame", "frame_long"),
             ("frame", "not_mbus"), ("checksum", ""), ("no_reply", "")],
        )

    def test_transmit_guard_follows_engine_option(self):
        with tempfile.TemporaryDirectory() as directory:
            old_options = webui.OPTIONS_JSON
            webui.OPTIONS_JSON = Path(directory) / "options.json"
            try:
                webui.OPTIONS_JSON.write_text(json.dumps({"mbus_enabled": False}))
                self.assertEqual(webui.mbus_transmit_allowed(), (True, ""))
                webui.OPTIONS_JSON.write_text(json.dumps({"mbus_enabled": True}))
                allowed, reason = webui.mbus_transmit_allowed()
            finally:
                webui.OPTIONS_JSON = old_options
        self.assertFalse(allowed)
        self.assertIn("bus master", reason)

    def test_poll_once_rejects_factory_and_reserved_addresses_before_io(self):
        for address in (0, 251, 68123456):
            with self.subTest(address=address):
                self.assertEqual(
                    webui.mbus_poll_once("/path/that/does/not/matter", address),
                    ("bad_address", ""),
                )

    def test_scan_range_is_ordered_clamped_and_capped(self):
        self.assertEqual(webui.mbus_scan_range(1, 250), (1, 32))
        self.assertEqual(webui.mbus_scan_range(50, 20), (20, 50))
        self.assertEqual(webui.mbus_scan_range(-10, 999), (1, 32))
        self.assertEqual(webui.mbus_scan_range(250, 250), (250, 250))


if __name__ == "__main__":
    unittest.main()
