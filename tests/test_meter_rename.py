"""Renaming a configured meter.

The label a user types is stored as the options entry's `id`. That value
travels: refresh_meter_files writes it as `name=` in the wmbusmeters meter
file, the decoder echoes it back as `.name` in every telegram, and
emit_discovery_from_json builds the Home Assistant device name from it.

What must NOT travel is entity identity: unique_id is built from the meter
id (`wmbus_<meter_id>_<field>`), so a rename keeps every entity and its
recorded history. These tests pin that contract down, because the obvious
"simplification" — keying discovery on the label — would silently orphan a
user's history the first time they fix a typo.
"""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "rootfs" / "usr" / "bin"))


class MeterRenameTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.mkdtemp()
        os.environ["WMBUS_BASE"] = self.tmp
        # No Supervisor in CI: update_meter_in_options falls back to a plain
        # file write, which is the path under test here anyway.
        os.environ.pop("SUPERVISOR_TOKEN", None)

        import webui

        self.webui = webui
        webui.OPTIONS_JSON = Path(self.tmp) / "options.json"
        # Event logging writes to a status file the tests do not care about.
        webui.webui_add_event = lambda *a, **k: None
        self._write([
            {"id": "kuchnia", "meter_id": "03528107", "type": "bmt",
             "type_other": "", "key": ""},
            {"id": "lazienka", "meter_id": "03534113", "type": "bmt",
             "type_other": "", "key": ""},
        ])

    def _write(self, meters: list) -> None:
        self.webui.write_json_atomic(self.webui.OPTIONS_JSON, {"meters": meters})

    def _meters(self) -> list:
        return self.webui.read_json(self.webui.OPTIONS_JSON)["meters"]

    def _entry(self, meter_id: str) -> dict:
        return next(m for m in self._meters()
                    if self.webui.normalize_meter_id(m["meter_id"]) == meter_id)

    def test_rename_changes_only_the_label(self) -> None:
        ok, _ = self.webui.update_meter_in_options(
            "03528107", "bmt", meter_name="Salon duzy")
        self.assertTrue(ok)
        entry = self._entry("03528107")
        self.assertEqual(entry["id"], "Salon_duzy")
        # The identity the discovery topics are keyed on must be untouched.
        self.assertEqual(entry["meter_id"], "03528107")

    def test_unicode_letters_survive(self) -> None:
        """A Polish or Czech label stays readable.

        Collapsing accented letters to ASCII would make the device name in HA
        differ from what the user typed, for no gain: the label is a display
        string, not a topic segment.
        """
        for label, expected in (
            ("Łazienka (góra) #2", "Łazienka_góra_2"),
            ("Kuchnia — parter", "Kuchnia_parter"),
            ("Sklep Čech/Slovák", "Sklep_Čech_Slovák"),
        ):
            ok, _ = self.webui.update_meter_in_options(
                "03534113", "bmt", meter_name=label)
            self.assertTrue(ok, label)
            self.assertEqual(self._entry("03534113")["id"], expected)

    def test_duplicate_label_is_refused(self) -> None:
        """Two meters may not share one label.

        wmbusmeters writes one meter file per name, so a duplicate would make
        the second silently overwrite the first — the meter would simply stop
        decoding with nothing in the log to explain it.
        """
        ok, _ = self.webui.update_meter_in_options(
            "03528107", "bmt", meter_name="Wspolna")
        self.assertTrue(ok)

        ok, msg = self.webui.update_meter_in_options(
            "03534113", "bmt", meter_name="Wspolna")
        self.assertFalse(ok)
        self.assertIn("already used", msg)
        # The refused write must not have touched either entry.
        self.assertEqual(self._entry("03528107")["id"], "Wspolna")
        self.assertEqual(self._entry("03534113")["id"], "lazienka")

    def test_renaming_a_meter_to_its_own_label_is_allowed(self) -> None:
        """Saving the dialog without touching the name must not self-collide."""
        ok, _ = self.webui.update_meter_in_options(
            "03528107", "bmt", meter_name="kuchnia")
        self.assertTrue(ok)
        self.assertEqual(self._entry("03528107")["id"], "kuchnia")

    def test_empty_label_falls_back_to_generated_name(self) -> None:
        """Clearing the field is symmetrical with adding a meter unnamed."""
        ok, _ = self.webui.update_meter_in_options(
            "03528107", "bmt", meter_name="")
        self.assertTrue(ok)
        self.assertEqual(self._entry("03528107")["id"], "meter_03528107")

    def test_absent_label_keeps_the_current_one(self) -> None:
        """None means "the caller did not touch the name".

        The exclude-field toggle posts to the same endpoint without a name, so
        treating absent as "clear it" would rename meters behind the user's
        back every time they hid a field.
        """
        ok, _ = self.webui.update_meter_in_options("03528107", "evo868")
        self.assertTrue(ok)
        entry = self._entry("03528107")
        self.assertEqual(entry["id"], "kuchnia")
        self.assertEqual(entry["type"], "evo868")

    def test_message_names_what_changed(self) -> None:
        """A rename and a driver change are different reasons to open the dialog."""
        _, msg = self.webui.update_meter_in_options(
            "03528107", "bmt", meter_name="Nowa")
        self.assertIn("renamed kuchnia -> Nowa", msg)

        _, msg = self.webui.update_meter_in_options("03528107", "evo868")
        self.assertNotIn("renamed", msg)
        self.assertIn("driver evo868", msg)

    def test_rename_preserves_other_settings(self) -> None:
        """A rename must not quietly drop the field configuration."""
        self._write([{
            "id": "kuchnia", "meter_id": "03528107", "type": "bmt",
            "type_other": "", "key": "A" * 32,
            "exclude_fields": "history_*",
            "calculated_fields": "d=a - b",
            "static_fields": "location=kitchen",
        }])
        ok, _ = self.webui.update_meter_in_options(
            "03528107", "bmt", meter_name="Salon")
        self.assertTrue(ok)
        entry = self._entry("03528107")
        self.assertEqual(entry["id"], "Salon")
        self.assertEqual(entry["key"], "A" * 32)
        self.assertEqual(entry["exclude_fields"], "history_*")
        self.assertEqual(entry["calculated_fields"], "d=a - b")
        self.assertEqual(entry["static_fields"], "location=kitchen")


if __name__ == "__main__":
    unittest.main()
