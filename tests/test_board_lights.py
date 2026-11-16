#!/usr/bin/env python3
"""Status lights (board_lights.py): the hourly collector fed by the 60 s
diag/summary, the verdict of the four lights, and their place in the WebUI's
board diagnostics."""

import importlib.util
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "rootfs" / "usr" / "bin"
sys.path.insert(0, str(BIN))
os.environ["TZ"] = "UTC"
time.tzset()

import board_lights as bl  # noqa: E402

_TMP = tempfile.TemporaryDirectory()
BASE = Path(_TMP.name)
os.environ["WMBUS_BASE"] = str(BASE)
SPEC = importlib.util.spec_from_file_location("wmbus_webui_board_lights", BIN / "webui.py")
webui = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(webui)

T = 1794304800  # 2026-11-10 10:00 UTC
H = 3600


def summ(irq=30, total=30, dropped=1, truncated=0, overrun=0, no_data=0, sym=1000, sym_bad=10):
    return {"event": "summary", "irq_fired": irq, "total": total, "dropped": dropped, "truncated": truncated,
            "t1": {"sym_total": sym, "sym_invalid": sym_bad},
            "rx_path": {"irq_fired": irq, "fifo_overrun": overrun, "irq_start": {"no_data": no_data}}}


def ev(rows, last, now, pulse=30, reboots=0, s1=False):
    return bl.evaluate(rows, last, now, pulse_age_s=pulse, reboots_24h=reboots, last_boot=T, s1_only=s1)


class Collector(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "hours.json")
        self.now = os.path.join(self.dir.name, "now.json")

    def tearDown(self):
        self.dir.cleanup()

    def test_summaries_are_summed_per_hour_and_closed_hours_kept(self):
        c = bl.BoardLights(self.path, self.now)
        c.summary("cc1101", summ(irq=30, total=28, dropped=2, overrun=1, no_data=1), T + 60)
        c.summary("cc1101", summ(irq=20, total=20, dropped=0, truncated=1), T + 120)
        c.summary("cc1101", {"event": "other", "irq_fired": 999}, T + 130)  # not a summary
        c.summary("cc1101", summ(), T + H + 60)  # rolls the hour over
        data = json.loads(Path(self.path).read_text())
        self.assertEqual(data["boards"]["cc1101"], [[T, 2, 50, 1, 48, 2, 1, 1, 2000, 20]])
        self.assertEqual(data["last"]["cc1101"]["overrun"], T + 60)
        self.assertEqual(data["last"]["cc1101"]["truncated"], T + 120)

    def test_hour_in_progress_survives_a_restart_and_reaches_the_webui(self):
        c = bl.BoardLights(self.path, self.now)
        c.summary("tbeam", summ(irq=5), T + 60)
        c2 = bl.BoardLights(self.path, self.now)
        self.assertEqual(c2.cur["tbeam"][2], 5)
        self.assertEqual(c2.last["tbeam"]["irq"], T + 60)
        loaded = bl.load(self.path, self.now)
        self.assertEqual(loaded["boards"]["tbeam"][0][:3], [T, 1, 5])


class Verdict(unittest.TestCase):
    def day(self, n=24, **kw):
        """n hours ending at T, one summary a minute each."""
        s = summ(**kw)
        row = [0, 60, s["irq_fired"] * 60, s["rx_path"]["irq_start"]["no_data"] * 60, s["total"] * 60,
               s["dropped"] * 60, s["truncated"] * 60, s["rx_path"]["fifo_overrun"] * 60,
               s["t1"]["sym_total"] * 60, s["t1"]["sym_invalid"] * 60]
        return [[T - (n - 1 - i) * H] + row[1:] for i in range(n)]

    def test_all_green(self):
        lights = ev(self.day(), {"irq": T + 30, "summary": T + 30}, T + 60)
        self.assertEqual({k: v["state"] for k, v in lights.items()},
                         {"alive": "ok", "radio": "ok", "keeps_up": "ok", "reception": "ok"})

    def test_no_summaries_leave_three_lights_without_data(self):
        lights = ev([], {}, T)
        self.assertEqual(lights["alive"]["state"], "ok")
        self.assertEqual([lights[k]["state"] for k in ("radio", "keeps_up", "reception")], ["none"] * 3)
        self.assertEqual(ev([], {}, T, pulse=None)["alive"]["state"], "none")

    def test_alive_follows_pulse_and_restarts(self):
        rows, last = self.day(), {"irq": T, "summary": T}
        self.assertEqual(ev(rows, last, T, reboots=1)["alive"]["state"], "ok")  # reflashing is normal
        self.assertEqual(ev(rows, last, T, reboots=2)["alive"]["state"], "warn")
        self.assertEqual(ev(rows, last, T, reboots=3)["alive"]["state"], "bad")
        self.assertEqual(ev(rows, last, T, pulse=400)["alive"]["state"], "bad")

    def test_one_overrun_in_the_day_turns_keeps_up_red_until_it_is_a_day_old(self):
        rows = self.day()
        rows[3][7] = 1
        last = {"irq": T, "summary": T, "overrun": rows[3][0] + 600}
        k = ev(rows, last, T)["keeps_up"]
        self.assertEqual((k["state"], k["overrun"], k["last"]), ("bad", 1, rows[3][0] + 600))
        # 24 hours later that hour has left the window.
        self.assertEqual(ev(rows, last, T + 4 * H)["keeps_up"]["state"], "ok")

    def test_a_silent_radio_is_red_but_not_on_s1(self):
        rows = self.day()
        last = {"irq": T - 2 * H, "summary": T}
        self.assertEqual(ev(rows, last, T)["radio"]["state"], "bad")
        self.assertTrue(ev(rows, last, T)["radio"]["deaf"])
        self.assertEqual(ev(rows, last, T, s1=True)["radio"]["state"], "ok")
        self.assertEqual(ev(rows, {"irq": T - 7 * H, "summary": T}, T, s1=True)["radio"]["state"], "bad")
        # A board that stopped sending summaries says nothing about its radio.
        self.assertEqual(ev(rows, {"irq": T - 2 * H, "summary": T - 2 * H}, T)["radio"]["state"], "ok")

    def test_interrupts_without_data(self):
        rows = self.day(irq=30, no_data=3)
        self.assertEqual(ev(rows, {"irq": T, "summary": T}, T)["radio"]["state"], "warn")
        rows = self.day(irq=300, no_data=1)  # 0.3 %: normal
        self.assertEqual(ev(rows, {"irq": T, "summary": T}, T)["radio"]["state"], "ok")

    def test_reception_against_the_boards_own_earlier_days(self):
        earlier = [[r[0] - 2 * 86400] + r[1:] for r in self.day(n=24, total=30, dropped=6)]  # 20 % is its normal
        today = self.day(total=30, dropped=6)
        r = ev(earlier + today, {"irq": T, "summary": T}, T)["reception"]
        self.assertEqual((r["state"], r["drop_typ"]), ("ok", 20.0))
        worse = self.day(total=30, dropped=15)  # 50 %
        self.assertEqual(ev(earlier + worse, {"irq": T, "summary": T}, T)["reception"]["state"], "warn")
        # Without earlier days the board is learning: never yellow, even at
        # 50 % (a board in `both` normally rejects 10-20 %).
        r = ev(self.day(total=30, dropped=15), {"irq": T, "summary": T}, T)["reception"]
        self.assertEqual((r["state"], r["learning"]), ("ok", True))
        self.assertFalse(ev(earlier + today, {"irq": T, "summary": T}, T)["reception"]["learning"])


class Payload(unittest.TestCase):
    def test_board_diagnostics_carry_the_lights(self):
        now = int(time.time())
        hour = now - now % H
        bl._write_json(str(webui.BOARD_LIGHTS_FILE), {"v": 1, "boards": {"tbeam": [[hour, 30, 0, 0, 0, 0, 0, 2, 0, 0]]},
                                                      "last": {"tbeam": {"summary": now - 30, "irq": 0, "overrun": now - 600}}})
        self.addCleanup(webui.BOARD_LIGHTS_FILE.unlink, True)
        webui.STATUS_ESP_HEALTH_JSON.parent.mkdir(parents=True, exist_ok=True)
        webui.STATUS_ESP_HEALTH_JSON.write_text(json.dumps({"tbeam": {"_bridge_rx_epoch": now - 20, "listen_mode": "S1"}}))
        self.addCleanup(webui.STATUS_ESP_HEALTH_JSON.unlink, True)
        webui.STATUS_ESP_CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
        webui.STATUS_ESP_CONFIG_FILE.write_text(json.dumps({"tbeam": {"lines": ["radio_type: SX1262"]}}))
        self.addCleanup(webui.STATUS_ESP_CONFIG_FILE.unlink, True)
        devs = {d["name"]: d for d in webui._esp_diag_payload()["devices"]}
        lights = devs["tbeam"]["lights"]
        self.assertEqual(lights["alive"]["state"], "ok")
        self.assertEqual(lights["keeps_up"]["state"], "bad")
        # S1, half an hour of summaries without an interrupt: quiet, not deaf.
        self.assertEqual(lights["radio"]["state"], "ok")


if __name__ == "__main__":
    unittest.main()
