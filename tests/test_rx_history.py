"""RX history kept by time (esp_rx_history_hours) and its download piece by piece:
bridge_ledger.py rx_history_policy and trim_history_by_time, webui.py
esp_rx_export_chunks and /api/esp-rx with hours.
"""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / "rootfs" / "usr" / "bin"
sys.path.insert(0, str(BIN))

import bridge_ledger as bl  # noqa: E402

SPEC = importlib.util.spec_from_file_location("wmbus_webui_rx", BIN / "webui.py")
webui = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(webui)

NOW = 1_800_000_000
GIB = 1 << 30


def event(ts: int, seq: int = 0) -> str:
    return json.dumps({"bridge_rx_time": ts, "source": "b", "seq": seq, "meter_id": "1",
                       "topic": "not in the export"}, separators=(",", ":"))


class Dir(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.path = os.path.join(self.dir, "history")
        patcher = mock.patch.object(bl, "now", lambda: float(NOW))
        patcher.start()
        self.addCleanup(patcher.stop)

    def write(self, stamps):
        with open(self.path, "w", encoding="utf-8") as fh:
            for i, ts in enumerate(stamps):
                fh.write(event(ts, i) + "\n")

    def stamps(self):
        with open(self.path, encoding="utf-8") as fh:
            return [json.loads(line)["bridge_rx_time"] for line in fh]


def statvfs(free: int):
    return mock.patch.object(bl.os, "statvfs", lambda _p: mock.Mock(f_bavail=free, f_frsize=1))


class Policy(Dir):
    def meminfo(self, kb: int) -> str:
        path = os.path.join(self.dir, "meminfo")
        Path(path).write_text(f"MemFree: 1 kB\nMemTotal:  {kb} kB\n", encoding="utf-8")
        return path

    def test_zero_is_the_limit_in_lines(self):
        self.assertEqual(bl.rx_history_policy(0, self.dir),
                         {"requested": 0, "effective": 0, "reason": ""})

    def test_allowed_with_ram_and_disk(self):
        with statvfs(10 * GIB):
            got = bl.rx_history_policy(24, self.dir, meminfo=self.meminfo(8 << 20))
        self.assertEqual(got, {"requested": 24, "effective": 24, "reason": ""})

    def test_refused_on_sd_ram_disk(self):
        with statvfs(10 * GIB):
            self.assertEqual(bl.rx_history_policy(24, self.dir, kind="sd", meminfo=self.meminfo(8 << 20))["reason"], "sd")
            self.assertEqual(bl.rx_history_policy(24, self.dir, meminfo=self.meminfo(1 << 20))["reason"], "ram")
        with statvfs(GIB):
            got = bl.rx_history_policy(24, self.dir, meminfo=self.meminfo(8 << 20))
        self.assertEqual((got["effective"], got["reason"]), (0, "disk"))

    def test_own_history_counts_as_free(self):
        # A long history must not refuse itself at the next start.
        with open(self.path, "wb") as fh:
            fh.truncate(GIB + 1)
        with statvfs(GIB):
            got = bl.rx_history_policy(24, self.dir, self.path, meminfo=self.meminfo(8 << 20))
        self.assertEqual(got["effective"], 24)

    def test_command_prints_hours_and_writes_json(self):
        out = os.path.join(self.dir, "policy.json")
        storage = os.path.join(self.dir, "storage.json")
        Path(storage).write_text('{"kind": "sd"}', encoding="utf-8")
        got = subprocess.run(
            [sys.executable, str(BIN / "bridge_ledger.py"), "rx-history-policy", "--hours", "24",
             "--path", self.dir, "--storage-file", storage, "--json-file", out],
            capture_output=True, text=True, check=True)
        self.assertEqual(got.stdout.strip(), "0")
        self.assertEqual(json.loads(Path(out).read_text(encoding="utf-8"))["reason"], "sd")


class Trim(Dir):
    def test_nothing_due_inside_the_margin(self):
        # 24 h asked, the oldest line 29 h old: under the quarter of margin.
        stamps = [NOW - 29 * 3600 + i for i in range(10)]
        self.write(stamps)
        with statvfs(10 * GIB):
            bl.trim_history_by_time(self.path, 24)
        self.assertEqual(self.stamps(), stamps)

    def test_late_keeps_the_asked_hours(self):
        # More than the bisection's block, so that it is exercised.
        stamps = [NOW - 40 * 3600 + i * 10 for i in range(14000)]
        self.write(stamps)
        with statvfs(10 * GIB):
            bl.trim_history_by_time(self.path, 24)
        kept = self.stamps()
        self.assertEqual(kept, [ts for ts in stamps if ts >= NOW - 24 * 3600])
        self.assertTrue(kept)
        self.assertEqual([n for n in os.listdir(self.dir) if ".tmp." in n], [])

    def test_above_max_bytes_keeps_the_newest_whole_lines(self):
        stamps = [NOW - 3600 + i for i in range(2000)]
        self.write(stamps)
        size = os.path.getsize(self.path)
        with statvfs(10 * GIB):
            bl.trim_history_by_time(self.path, 24, max_bytes=size // 2)
        kept = self.stamps()  # parses every line, so none was cut in half
        self.assertLessEqual(os.path.getsize(self.path), size // 2)
        self.assertEqual(kept[-1], stamps[-1])
        self.assertEqual(kept, stamps[-len(kept):])

    def test_low_disk_gives_way(self):
        stamps = [NOW - 3600 + i for i in range(2000)]
        self.write(stamps)
        size = os.path.getsize(self.path)
        with statvfs(100):
            bl.trim_history_by_time(self.path, 24, reserve=size // 2)
        self.assertLess(os.path.getsize(self.path), size)
        self.assertEqual(self.stamps()[-1], stamps[-1])

    def test_failure_leaves_the_file_and_no_exception(self):
        stamps = [NOW - 40 * 3600 + i for i in range(10)] + [NOW]
        self.write(stamps)
        with statvfs(10 * GIB), mock.patch.object(bl.shutil, "copyfileobj", side_effect=OSError("full")):
            bl.trim_history_by_time(self.path, 24)
        self.assertEqual(self.stamps(), stamps)
        self.assertEqual([n for n in os.listdir(self.dir) if ".tmp." in n], [])

    def test_missing_file_is_nothing(self):
        bl.trim_history_by_time(self.path, 24)

    def test_book_trims_by_time_only_when_asked(self):
        payload = json.dumps({"schema": 1, "boot_id": "a84f12c7", "seq": 1, "rx_task_wakeup_us": 123,
                              "meter_id": "11223344", "mode": "T1", "frame_crc32": "7f56a83c",
                              "frame_length": 123}).encode()
        for hours, called, other in ((0, "trim_locked", "trim_history_by_time"),
                                     (24, "trim_history_by_time", "trim_locked")):
            book = bl.RxBook(*(os.path.join(self.dir, n) for n in
                               ("reception", "mode", "history", "sequence", "boots", "clock")),
                             history_hours=hours)
            book.since_trim = book.TRIM_EVERY - 1
            with mock.patch.object(bl, called) as wanted, mock.patch.object(bl, other) as unwanted:
                book(b"wmbus/board/rx", payload)
            wanted.assert_called_once()
            unwanted.assert_not_called()


class Export(Dir):
    def setUp(self):
        super().setUp()
        self.hist = Path(self.path)
        self.diag = Path(self.dir) / "diag"
        self.missing = Path(self.dir) / "missing"
        for name, value in (("ESP_RF_RX_HISTORY_FILE", self.hist),
                            ("ESP_DIAG_HISTORY_FILE", self.diag),
                            ("STATUS_ESP_RX_RECEPTION_FILE", self.missing),
                            ("STATUS_ESP_RX_SEQUENCE_FILE", self.missing)):
            patcher = mock.patch.object(webui, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def chunks(self, limit=0, since=0, until=0, diagnostics=False):
        return json.loads(b"".join(webui.esp_rx_export_chunks(limit, since, until, NOW, diagnostics)))

    def test_same_as_the_payload_of_the_api(self):
        self.write([NOW + i for i in range(1205)])  # more than one batch
        with open(self.hist, "a", encoding="utf-8") as fh:
            fh.write("not json\n[1]\n")
        self.diag.write_text(
            json.dumps({"bridge_rx_time": NOW, "kind": "fifo_sample", "raw": "aa"}) + "\n"
            + json.dumps({"bridge_rx_time": NOW, "kind": "other"}) + "\nbroken\n", encoding="utf-8")
        whole = webui.esp_rx_api_payload(limit=100000, max_limit=100000, include_diagnostics=True)
        got = self.chunks(limit=100000, diagnostics=True)
        whole["generated_at"] = NOW
        self.assertEqual(got, whole)
        self.assertEqual(got["history_invalid_lines"], 2)
        self.assertEqual(got["diagnostics_history_invalid_lines"], 2)
        self.assertNotIn("topic", got["history"][0])

    def test_limit_keeps_the_newest_and_zero_keeps_all(self):
        self.write([NOW + i for i in range(10)])
        self.assertEqual([e["seq"] for e in self.chunks(limit=3)["history"]], [7, 8, 9])
        self.assertEqual(len(self.chunks()["history"]), 10)

    def test_empty_history_is_valid_json(self):
        got = self.chunks()
        self.assertEqual((got["history"], got["diagnostics_history"]), ([], []))

    def test_span_and_size_from_one_line(self):
        self.write([NOW - 7200, NOW])
        status = Path(self.dir) / "policy.json"
        status.write_text('{"requested": 24, "effective": 0, "reason": "sd"}', encoding="utf-8")
        with mock.patch.object(webui, "STATUS_ESP_RX_HISTORY_FILE", status), \
                mock.patch.object(webui.time, "time", lambda: float(NOW)):
            info = webui.rx_history_info()
        self.assertEqual((info["span_h"], info["reason"], info["effective"]), (2.0, "sd", 0))
        self.assertEqual(info["size_bytes"], self.hist.stat().st_size)

    def test_endpoint_hours_and_download(self):
        real_now = int(webui.time.time())
        self.write([real_now - 3 * 3600, real_now - 3600, real_now])
        options = Path(self.dir) / "options.json"
        options.write_text(json.dumps({"esp_rx_api_enabled": True}), encoding="utf-8")
        server = webui.ThreadingHTTPServer(("127.0.0.1", 0), webui.Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        url = f"http://127.0.0.1:{server.server_port}/api/esp-rx"
        try:
            with mock.patch.object(webui, "OPTIONS_JSON", options):
                with webui.urllib.request.urlopen(url + "?download=1&hours=2") as response:
                    self.assertRegex(response.headers.get("Content-Disposition", ""),
                                     r'^attachment; filename="esp-rx-\d{8}-\d{6}Z\.json"$')
                    self.assertIsNone(response.headers.get("Content-Length"))
                    self.assertEqual(len(json.load(response)["history"]), 2)
                with webui.urllib.request.urlopen(url + "?download=1") as response:
                    self.assertEqual(len(json.load(response)["history"]), 3)
                with webui.urllib.request.urlopen(url + "?hours=2") as response:
                    self.assertEqual(len(json.load(response)["history"]), 2)
                with self.assertRaises(webui.urllib.error.HTTPError) as bad:
                    webui.urllib.request.urlopen(url + "?hours=soon")
                self.assertEqual(bad.exception.code, 400)
                bad.exception.close()
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=2)


class Wiring(unittest.TestCase):
    def test_option_is_in_the_schema_and_translated(self):
        config = (ROOT / "config.yaml").read_text(encoding="utf-8")
        self.assertIn('esp_rx_history_hours: "0"', config)
        self.assertIn("esp_rx_history_hours: list(0|12|24|48|72)", config)
        for lang in ("en", "pl", "de", "cs", "sk"):
            text = (ROOT / "translations" / f"{lang}.yaml").read_text(encoding="utf-8")
            self.assertIn("esp_rx_history_hours:", text, lang)

    def test_start_does_not_cut_a_long_history_to_lines(self):
        esp = (BIN / "bridge-lib" / "13-esp.sh").read_text(encoding="utf-8")
        self.assertNotIn('_trim_esp_rx_history "${ESP_RF_RX_HISTORY_FILE}" 100000 90000 || true\n  while', esp)
        self.assertEqual(esp.count("_trim_esp_rf_rx_history_at_start"), 3)

    def test_publisher_book_gets_the_hours(self):
        self.assertIn('int(cfg.get("history_hours", 0))',
                      (BIN / "mqtt_publisher.py").read_text(encoding="utf-8"))
        self.assertIn("history_hours: $rx_hist_hours",
                      (BIN / "bridge-lib" / "12-pipeline.sh").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
