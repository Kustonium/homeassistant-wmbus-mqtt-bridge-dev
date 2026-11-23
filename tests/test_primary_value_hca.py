#!/usr/bin/env python3
"""The main value of a heat cost allocator is its current reading.

1.6.25 showed a Hydroclima allocator's average temperature on the tile: no
rule took a *_hca field as the main value, so the instant-value rule picked
the first *_c field. The current-period units must win, whatever the order of
the fields, over the set-date, end-of-month and target ones and over any
temperature; meters with a total keep it.
"""

import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "rootfs" / "usr" / "bin"))

import bridge_ledger  # noqa: E402


def line(**fields):
    return json.dumps({"_": "telegram", "id": "78240400", "media": "heat cost allocation", **fields})


class AllocatorMainValue(unittest.TestCase):
    def key(self, text, media="heat cost allocation"):
        return bridge_ledger.meter_value(text, media, "radiator", None)[:2]

    def test_hydroclima_names_of_1_6_25(self):
        text = line(consumption_at_set_date_hca=93.8, temperature_tu_c=19.4,
                    current_consumption_hca=51.7, temperature_tc_c=20.1)
        self.assertEqual(self.key(text), ("current_consumption_hca", "51.7"))

    def test_hydroclima_names_of_the_wmbusmeters_driver(self):
        text = line(target_hca=93.8, previous_average_ambient_temperature_c=19.4,
                    allocation_hca=51.7, average_ambient_temperature_c=20.1, previous_month_hca=40.2)
        self.assertEqual(self.key(text), ("allocation_hca", "51.7"))

    def test_history_only_frame_is_not_a_reading(self):
        text = line(consumption_end_of_month_1_hca=40.2, consumption_end_of_month_2_hca=30.1)
        prev = ["current_consumption_hca", "51.7", ""]
        self.assertEqual(bridge_ledger.meter_value(text, "heat cost allocation", "radiator", prev)[:2],
                         ("current_consumption_hca", "51.7"))

    def test_candidate_preview_picks_the_same_field(self):
        text = line(consumption_at_set_date_hca=93.8, temperature_tu_c=19.4, current_consumption_hca=51.7)
        self.assertEqual(bridge_ledger.select_primary_meter_value(text), "current_consumption_hca\t51.7")

    def test_water_meter_keeps_its_total(self):
        text = line(media="water", consumption_at_set_date_m3=10.0, total_m3=12.5, flow_temperature_c=11.0)
        self.assertEqual(self.key(text, "water"), ("total_m3", "12.5"))


if __name__ == "__main__":
    unittest.main()
