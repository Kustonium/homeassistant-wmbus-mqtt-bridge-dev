#!/usr/bin/env python3
"""Radio environment tab: the hourly collector (radio_env.py) and the
WebUI's comparison with the same hour on earlier days of the same kind."""

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

import radio_env  # noqa: E402

_TMP = tempfile.TemporaryDirectory()
BASE = Path(_TMP.name)
os.environ["WMBUS_BASE"] = str(BASE)
SPEC = importlib.util.spec_from_file_location("wmbus_webui_radio_env", BIN / "webui.py")
webui = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(webui)

# Tuesday 2026-11-10 10:00 UTC; the Tuesdays and Mondays before are working days.
T = 1794304800
H = 3600
D = 86400


class Collector(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "hours.json")
        self.now = os.path.join(self.dir.name, "now.json")

    def tearDown(self):
        self.dir.cleanup()

    def test_frames_weak_meters_and_symbols_per_hour(self):
        env = radio_env.RadioEnv(self.path, self.now)
        env.frame("lilygo", "03528107", -95, T + 10)
        env.frame("lilygo", "03528107", -70, T + 20)
        env.frame("lilygo", "00089907", None, T + 30)
        env.summary("lilygo", {"event": "summary", "t1": {"sym_total": 1000, "sym_invalid": 30}}, T + 60)
        env.summary("lilygo", {"event": "other", "t1": {"sym_total": 999, "sym_invalid": 999}}, T + 61)
        env.frame("lilygo", "03528107", -60, T + H + 5)  # rolls the hour over
        rows = json.loads(Path(self.path).read_text())["boards"]["lilygo"]
        self.assertEqual(rows, [[T, 3, 1, 2, 1000, 30]])

    def test_hour_in_progress_survives_a_restart(self):
        env = radio_env.RadioEnv(self.path, self.now)
        env.frame("tbeam", "1", -80, T + 100)
        env2 = radio_env.RadioEnv(self.path, self.now)
        env2.frame("tbeam", "2", -80, T + 200)
        env2.frame("tbeam", "2", -80, T + H)
        self.assertEqual(json.loads(Path(self.path).read_text())["boards"]["tbeam"], [[T, 2, 0, 2, 0, 0]])

    def test_bands_are_counted_under_their_own_keys(self):
        env = radio_env.RadioEnv(self.path, self.now)
        env.frame("lilygo", "1", -95, T + 10, "T1")
        env.frame("lilygo", "2", -70, T + 20, "C1")
        env.frame("lilygo", "3", -99, T + 1200, "S1")   # an S1 meter, late in the hour
        env.frame("lilygo", "4", -99, T + 30, "X9")     # unknown mode: only in the total
        env.summary("lilygo", {"event": "summary", "t1": {"sym_total": 1000, "sym_invalid": 30}}, T + 60)
        env.frame("lilygo", "1", -95, T + H + 5, "T1")
        env.frame("lilygo", "2", -70, T + H + 6, "C1")
        env.frame("lilygo", "3", -99, T + H + 7, "S1")
        boards = json.loads(Path(self.path).read_text())["boards"]
        self.assertEqual(boards["lilygo"], [[T, 4, 3, 4, 1000, 30]])
        self.assertEqual(boards["lilygo|T1"], [[T, 1, 1, 1, 1000, 30]])
        self.assertEqual(boards["lilygo|C1"], [[T, 1, 0, 1, 0, 0]])
        # Its first frame came 20 minutes in, but the board counted the whole
        # hour: the S1 hour is kept, not dropped as a partial one.
        self.assertEqual(boards["lilygo|S1"], [[T, 1, 1, 1, 0, 0]])

    def test_old_rows_are_dropped(self):
        env = radio_env.RadioEnv(self.path, self.now)
        env.frame("x", "1", -80, T - 20 * D)
        env.frame("x", "1", -80, T)
        env.frame("x", "1", -80, T + H)
        hours = [r[0] for r in json.loads(Path(self.path).read_text())["boards"]["x"]]
        self.assertEqual(hours, [T])


class Payload(unittest.TestCase):
    def write(self, boards, now_boards=None):
        webui.RADIO_ENV_FILE.write_text(json.dumps({"v": 1, "boards": boards}))
        webui.RADIO_ENV_NOW_FILE.write_text(json.dumps({"v": 1, "boards": now_boards or {}}))

    def history(self, frames, days=(1, 7, 8), weak=5, sym=(10000, 100)):
        # The 10:00 hour on earlier working days, plus the hour before now.
        rows = [[T - d * D, frames, weak, 50, sym[0], sym[1]] for d in sorted(days, reverse=True)]
        return rows

    def test_learning_without_three_earlier_days(self):
        self.write({"a": [[T - H, 1000, 1, 10, 0, 0]]})
        p = webui.radio_env_payload(T + 1800)
        self.assertEqual(p["verdict"], "learning")
        self.assertEqual(p["boards"][0]["state"], "learning")

    def test_normal_and_one_board(self):
        boards = {}
        for name, now_frames in (("a", 1000), ("b", 1000), ("c", 400)):
            boards[name] = self.history(1000) + [[T - H, now_frames, 5, 50, 10000, 100]]
        self.write(boards, {n: {"hour": T, "frames": 0} for n in boards})
        p = webui.radio_env_payload(T + 60)
        states = {b["name"]: b["state"] for b in p["boards"]}
        self.assertEqual(states, {"a": "normal", "b": "normal", "c": "fewer"})
        self.assertEqual((p["verdict"], p["odd_board"]), ("one_board", "c"))

    def test_collisions_when_all_busier_with_errors(self):
        boards = {n: self.history(1000) + [[T - H, 2000, 5, 50, 10000, 900]] for n in ("a", "b")}
        self.write(boards, {n: {"hour": T, "frames": 0} for n in boards})
        p = webui.radio_env_payload(T + 60)
        self.assertEqual(p["verdict"], "collisions")

    def test_silent_board(self):
        self.write({"a": self.history(1000) + [[T - 3 * H, 900, 5, 50, 0, 0]]})
        p = webui.radio_env_payload(T + 60)
        self.assertEqual(p["boards"][0]["state"], "silent")
        self.assertEqual(p["verdict"], "silent")

    def test_heatmap_and_far_meters(self):
        boards = {"a": self.history(1000, weak=40) + [[T - 5 * H, 100, 2, 10, 0, 0]]}
        self.write(boards)
        p = webui.radio_env_payload(T + 60)
        tue = time.localtime(T - 7 * D).tm_wday
        self.assertEqual(p["heat"][tue][10], 1000)
        self.assertEqual(p["far"][10], 40)
        self.assertEqual(p["far_best"], [])        # three days of one hour: no advice yet

    def test_far_best_needs_most_of_the_day(self):
        rows = []
        for d in (1, 6, 7, 8):                      # Mon, Wed, Tue, Mon before: working days
            for h in range(24):
                ts = T - d * D - 10 * H + h * H
                rows.append([ts, 100, 40 if h < 5 or h >= 21 else 5, 10, 0, 0])
        rows.sort()
        self.write({"a": rows + [[T - H, 100, 5, 10, 0, 0]]}, {"a": {"hour": T, "frames": 0}})
        p = webui.radio_env_payload(T + 60)
        self.assertEqual(p["far_best"], [0, 1, 2, 3, 4, 21, 22, 23])

    def test_one_dead_board_is_a_finding(self):
        boards = {n: self.history(1000) + [[T - H, 1000, 5, 50, 10000, 100]] for n in ("a", "b")}
        boards["dead"] = self.history(1000)        # last heard a day ago, minus a bit
        boards["dead"][-1][0] = T - 20 * H
        self.write(boards, {n: {"hour": T, "frames": 0} for n in ("a", "b")})
        p = webui.radio_env_payload(T + 60)
        self.assertEqual((p["verdict"], p["odd_board"]), ("one_board", "dead"))

    def test_one_silent_board_among_learning_ones_is_not_all_silent(self):
        # Prod 12.11: five boards still learning (no three earlier days), one
        # board silent (moved to another broker). The silent one was the only
        # "known" board, so the verdict said no frames from the boards at all.
        boards = {n: [[T - H, 1000, 5, 50, 10000, 100]] for n in ("a", "b")}
        boards["moved"] = [[T - 20 * H, 900, 5, 50, 0, 0]]
        self.write(boards, {n: {"hour": T, "frames": 0} for n in ("a", "b")})
        p = webui.radio_env_payload(T + 60)
        self.assertEqual({b["name"]: b["state"] for b in p["boards"]},
                         {"a": "learning", "b": "learning", "moved": "silent"})
        self.assertEqual((p["verdict"], p["odd_board"]), ("one_board", "moved"))

    def test_a_board_gone_for_a_day_is_not_shown(self):
        boards = {n: self.history(1000) + [[T - H, 1000, 5, 50, 10000, 100]] for n in ("a", "b")}
        boards["gone"] = [[T - 3 * D, 900, 1, 10, 0, 0]]
        self.write(boards, {n: {"hour": T, "frames": 0} for n in ("a", "b")})
        p = webui.radio_env_payload(T + 60)
        self.assertNotIn("gone", [b["name"] for b in p["boards"]])
        self.assertEqual(p["verdict"], "normal")

    def test_empty(self):
        self.write({})
        self.assertTrue(webui.radio_env_payload(T)["empty"])

    def settings(self, modes):
        webui.STATUS_ESP_SETTINGS_FILE.parent.mkdir(parents=True, exist_ok=True)
        webui.STATUS_ESP_SETTINGS_FILE.write_text(json.dumps(
            {n: {"v": 1, "listen_mode": {"value": m}} for n, m in modes.items()}))
        self.addCleanup(webui.STATUS_ESP_SETTINGS_FILE.unlink, True)

    def test_all_view_ignores_band_keys_and_names_listen_modes(self):
        row = [[T - H, 1000, 5, 50, 0, 0]]
        self.write({"a": row, "a|T1": row, "b": row, "b|S1": row})
        self.settings({"a": "both", "b": "s1"})
        p = webui.radio_env_payload(T + 60)
        self.assertEqual(p["band"], "all")
        self.assertEqual({b["name"]: b["listen_mode"] for b in p["boards"]}, {"a": "both", "b": "s1"})

    def test_band_view_shows_the_boards_listening_to_it(self):
        row = [[T - H, 300, 5, 20, 0, 0]]
        # c heard S1 earlier but listens to T1 now; d listens to S1 and has
        # heard nothing in it yet.
        self.write({"a": row, "a|T1": row, "b": row, "b|S1": row, "c": row, "c|S1": row, "d": row})
        self.settings({"a": "both", "b": "s1", "c": "t1", "d": "s1"})
        p = webui.radio_env_payload(T + 60, band="S1")
        self.assertEqual(p["band"], "S1")
        states = {b["name"]: b["state"] for b in p["boards"]}
        self.assertEqual(states, {"b": "learning", "d": "learning"})
        self.assertEqual(webui.radio_env_payload(T + 60, band="nonsense")["band"], "all")

    def test_band_view_without_frames_or_listeners_is_empty(self):
        row = [[T - H, 300, 5, 20, 0, 0]]
        self.write({"a": row, "a|T1": row})
        self.settings({"a": "t1"})
        p = webui.radio_env_payload(T + 60, band="C1")
        self.assertTrue(p["empty"])
        self.assertEqual(p["band"], "C1")



class Hooks(unittest.TestCase):
    """The books feed the collector only with RADIO_ENV_FILE set."""

    def setUp(self):
        import bridge_ledger as bl
        import esp_books
        self.bl, self.esp = bl, esp_books
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        d = Path(self.dir.name)
        os.environ["RADIO_ENV_FILE"] = str(d / "hours.json")
        os.environ["RADIO_ENV_NOW_FILE"] = str(d / "now.json")
        self.addCleanup(os.environ.pop, "RADIO_ENV_FILE", None)
        self.addCleanup(os.environ.pop, "RADIO_ENV_NOW_FILE", None)
        radio_env._INSTANCE = None
        self.addCleanup(setattr, radio_env, "_INSTANCE", None)
        self.addCleanup(setattr, bl, "now", bl.now)
        bl.now = lambda: float(T + 10)
        self.d = d

    def test_rx_and_summary_reach_the_collector(self):
        files = [str(self.d / n) for n in ("reception", "mode", "history", "sequence", "boots", "clock")]
        book = self.bl.RxBook(*files)
        base = ('"schema":1,"rx_task_wakeup_us":1,"mode":"T1","frame_crc32":"7F56A83C",'
                '"frame_length":10,"meter_id":"52632878","boot_id":"A84F12C7","seq":1,"rssi_dbm":-95')
        book(b"wmbus/lilygo/rx", ("{" + base + "}").encode())
        self.esp.SummaryBook(str(self.d / "summary.json"))(
            b"wmbus/lilygo/diag/summary", b'{"event":"summary","t1":{"sym_total":500,"sym_invalid":5}}')
        c = radio_env.instance().cur["lilygo"]
        self.assertEqual((c["frames"], c["weak"], c["meters"], c["sym_total"], c["sym_invalid"]),
                         (1, 1, {"52632878"}, 500, 5))
        c = radio_env.instance().cur["lilygo|T1"]
        self.assertEqual((c["frames"], c["sym_total"]), (1, 500))

    def test_without_the_variable_nothing_is_collected(self):
        os.environ.pop("RADIO_ENV_FILE")
        files = [str(self.d / n) for n in ("reception", "mode", "history", "sequence", "boots", "clock")]
        self.bl.RxBook(*files)(b"wmbus/lilygo/rx", b'{"schema":1,"mode":"T1","meter_id":"1","seq":1}')
        self.assertIsNone(radio_env._INSTANCE)



class StartedMidHour(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.path = os.path.join(self.dir.name, "hours.json")
        self.now = os.path.join(self.dir.name, "now.json")

    def test_a_partial_first_hour_is_not_stored(self):
        env = radio_env.RadioEnv(self.path, self.now)
        env.frame("a", "1", -80, T + 900)          # started 15 min into the hour
        env.frame("a", "1", -80, T + H + 10)       # next hour: counted from its start
        env.frame("a", "1", -80, T + 2 * H + 10)
        rows = json.loads(Path(self.path).read_text())["boards"]["a"]
        self.assertEqual([r[0] for r in rows], [T + H])

    def test_rate_uses_the_time_actually_counted(self):
        webui.RADIO_ENV_FILE.write_text(json.dumps({"v": 1, "boards": {}}))
        webui.RADIO_ENV_NOW_FILE.write_text(json.dumps({"v": 1, "boards": {
            "a": {"hour": T, "start": T + 900, "frames": 1}}}))
        b = webui.radio_env_payload(T + 1000)["boards"][0]
        self.assertIsNone(b["frames_h"])             # under 10 minutes counted
        webui.RADIO_ENV_NOW_FILE.write_text(json.dumps({"v": 1, "boards": {
            "a": {"hour": T, "start": T + 900, "frames": 100}}}))
        b = webui.radio_env_payload(T + 900 + 1200)["boards"][0]
        self.assertEqual(b["frames_h"], 300)         # 100 frames in 20 minutes


class LiveRate(unittest.TestCase):
    """The Panel's board rate: median frames/min of the last 15 complete minutes."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "hours.json")
        self.now = os.path.join(self.dir.name, "now.json")
        self.env = radio_env.RadioEnv(self.path, self.now)

    def tearDown(self):
        self.dir.cleanup()

    def minutes(self, board, start_min, counts):
        """counts[i] frames spread over minute start_min + i (from T)."""
        for i, n in enumerate(counts):
            m = T + (start_min + i) * 60
            for k in range(n):
                self.env.frame(board, str(k), -80, m + 1 + k * 50 // max(n, 1))
        # one frame of another board each minute keeps the file written
        return T + (start_min + len(counts)) * 60

    def rate(self, board, at):
        self.env.frame("other", "x", -80, at + 1)   # writes the file for the minute before
        return radio_env.live_rate(self.now, board, at + 30)

    def test_none_until_fifteen_minutes_are_counted(self):
        end = self.minutes("tbeam", 0, [10] * 10)
        self.assertIsNone(self.rate("tbeam", end))

    def test_steady_board(self):
        end = self.minutes("tbeam", 0, [10] * 20)
        self.assertEqual(self.rate("tbeam", end), 10.0)

    def test_board_moved_from_an_attenuator(self):
        # 20 minutes at 7/min (behind an attenuator), then moved: 54/min
        end = self.minutes("tbeam", 0, [7] * 20)
        self.assertEqual(self.rate("tbeam", end), 7.0)
        end = self.minutes("tbeam", 20, [54] * 8)    # 8 of the last 15 minutes after the move
        self.assertEqual(self.rate("tbeam", end), 54.0)   # the median follows the majority
        end = self.minutes("tbeam", 28, [54] * 7)
        self.assertEqual(self.rate("tbeam", end), 54.0)

    def test_silent_minutes_count_as_zero(self):
        end = self.minutes("s1board", 0, [3, 0] * 10)
        self.assertEqual(self.rate("s1board", end), 0.0)    # more silent minutes than busy ones

    def test_unknown_board_or_no_file(self):
        self.assertIsNone(radio_env.live_rate(self.now, "nobody", T))
        self.assertIsNone(radio_env.live_rate(os.path.join(self.dir.name, "missing.json"), "tbeam", T))


if __name__ == "__main__":
    unittest.main()
