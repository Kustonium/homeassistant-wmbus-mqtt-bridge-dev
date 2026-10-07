"""esp_books.py against the bash loops of 13-esp.sh it replaces.

For each ported subscriber the real loop is cut out of 13-esp.sh and run with
a mosquitto_sub stand-in that prints a corpus; the book gets the same corpus
through mqtt_publisher's delivery. The files they write must be identical,
byte for byte, after every step of a scenario. The clock is fixed on both
sides (`date`/epoch_now in bash, bridge_ledger.now in Python).
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "rootfs" / "usr" / "bin"))

import bridge_ledger as bl  # noqa: E402
import esp_books  # noqa: E402
import mqtt_publisher as mp  # noqa: E402

LIB = ROOT / "rootfs" / "usr" / "bin" / "bridge-lib" / "13-esp.sh"
TSV_LIB = ROOT / "rootfs" / "usr" / "bin" / "bridge-lib" / "03-tsv.sh"
NOW = 1790000000


def loop_block(marker: str) -> str:
    """The `( ... ) &` subscriber block guarded by the comment naming marker."""
    lines = LIB.read_text(encoding="utf-8").replace("\r\n", "\n").split("\n")
    start = next(i for i, l in enumerate(lines) if f"(esp_books.{marker})" in l)
    begin = next(i for i in range(start, len(lines)) if lines[i] == "(")
    end = next(i for i in range(begin, len(lines)) if lines[i] == ") &")
    return "\n".join(lines[begin:end + 1])


def shell_function(path: Path, name: str) -> str:
    """The definition `name() {` ... `}` (closing brace at column 0) from path."""
    lines = path.read_text(encoding="utf-8").replace("\r\n", "\n").split("\n")
    begin = next(i for i, l in enumerate(lines) if l.startswith(f"{name}() {{"))
    end = next(i for i in range(begin, len(lines)) if lines[i] == "}")
    return "\n".join(lines[begin:end + 1])


def run_bash(block: str, corpus: bytes, env_vars: dict) -> None:
    with tempfile.TemporaryDirectory() as d:
        stub = os.path.join(d, "mosquitto_sub_stub")
        data = os.path.join(d, "corpus")
        Path(data).write_bytes(corpus)
        Path(stub).write_text(f'#!/usr/bin/env bash\ncat "{data}"\n')
        os.chmod(stub, 0o755)
        script = "\n".join([
            "set -uo pipefail",
            *(f"{k}='{v}'" for k, v in env_vars.items()),
            f"STDBUF_BIN='{stub}'", "SUB_ARGS=()", 'ESP_SUBSCRIBER_PIDS=""',
            f"date() {{ echo {NOW}; }}", f"epoch_now() {{ echo {NOW}; }}",
            "log() { :; }", "_sub_reconnect_sleep() { exit 0; }",
            block, "wait",
        ])
        subprocess.run(["bash", "-c", script], check=True, timeout=30)


def run_python(book, corpus_messages, payload_only=False):
    deliver = mp._deliver_lines(book, "test", payload_only=payload_only)
    for topic, payload in corpus_messages:
        deliver(topic, payload)


def read(path):
    try:
        return Path(path).read_bytes()
    except OSError:
        return None


class EspBooksTests(unittest.TestCase):
    def setUp(self):
        self._now = bl.now
        bl.now = lambda: float(NOW)
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        bl.now = self._now
        shutil.rmtree(self.tmp, ignore_errors=True)

    def compare_steps(self, marker, book_factory, steps, var, payload_only=False, seed=None):
        """steps: lists of (topic, payload); the file is compared after each."""
        bash_file = os.path.join(self.tmp, "bash.out")
        py_file = os.path.join(self.tmp, "py.out")
        for f in (bash_file, py_file):
            if seed is not None:
                Path(f).write_bytes(seed)
        book = book_factory(py_file)
        block = loop_block(marker)
        for n, messages in enumerate(steps):
            if payload_only:
                corpus = b"".join(p + b"\n" for _, p in messages)
            else:
                corpus = b"".join(t + b"\t" + p + b"\n" for t, p in messages)
            run_bash(block, corpus, {var: bash_file, "DISCOVERY_PREFIX": "homeassistant"})
            run_python(book, messages, payload_only)
            self.assertEqual(read(py_file), read(bash_file), f"{marker} step {n}")
        return read(py_file)

    def test_health(self):
        steps = [
            [(b"wmbus/lilygo/health",
              b'{"uptime_s":12,"rx_total":5,"sec_since_last_rx":3,"chip":"SX1276","listen_mode":"T1"}')],
            [(b"wmbus/heltec/health",
              '{"uptime_s":1.50,"nested":{"a":[1,2,{"b":null}],"e":[],"o":{}},"s":"zażółć \\"q\\""}'.encode()),
             (b"wmbus/lilygo/health", b'{"uptime_s":13,"_bridge_rx_epoch":5}')],
            [(b"wmbus/x/health", b"not json"), (b"wmbus/x/health", b"42"), (b"wmbus/x/health", b"1 2"),
             (b"wmbus/y/health", b""), (b"other/health", b'{"a":1}'), (b"wmbus/health", b'{"a":1}'),
             (b"wmbus/a/b/health", b'{"deep":true}'), (b"wmbus/t/health", b'\t{"tabs": 1 }\t'),
             (b"wmbus/z/health", b'{"multi":1}\n{"line":2}')],
        ]
        out = self.compare_steps("HealthBook", esp_books.HealthBook, steps, "STATUS_ESP_HEALTH_FILE")
        self.assertIn(b'"lilygo"', out)
        self.assertIn(b'"_bridge_rx_epoch": %d' % NOW, out)

    def test_health_keeps_a_broken_file(self):
        steps = [[(b"wmbus/lilygo/health", b'{"uptime_s":1}')]]
        for seed in (b"garbage", b'{"a":1} x', b"[1,2]", b'{"a":1}\n{"b":2}\n', b"\n"):
            with self.subTest(seed=seed):
                self.compare_steps("HealthBook", esp_books.HealthBook, steps, "STATUS_ESP_HEALTH_FILE", seed=seed)

    def test_meters(self):
        steps = [
            [(b"wmbus/lilygo/meters", b'{"target":"03534159","highlight":["12345678","00089907"]}')],
            [(b"wmbus/heltec/meters", b'{"target":"","highlight":[]}'),
             (b"wmbus/lilygo/meters", b'{"target":"03534159","highlight":[]}'),
             (b"wmbus/x/meters", b"[1]"), (b"wmbus/meters", b'{"a":1}'), (b"wmbus/x/health", b'{"a":1}')],
        ]
        out = self.compare_steps("MetersBook", esp_books.MetersBook, steps, "STATUS_ESP_METERS_FILE")
        self.assertIn(b'"heltec"', out)

    def test_meter_snapshot(self):
        snap = (b'{"meters":[{"id":"03534159","mode":"T1","count_window":12,"avg_interval_s":120.5,'
                b'"elapsed_s":900}],"window_s":900}')
        steps = [
            [(b"wmbus/tbeam/diag/meter_snapshot", snap)],
            [(b"wmbus/lilygo/diag/meter_snapshot", snap), (b"wmbus/tbeam/diag/meter_snapshot", b"{}"),
             (b"wmbus/diag/meter_snapshot", snap), (b"wmbus/x/diag/meter_snapshot/extra", snap)],
        ]
        out = self.compare_steps("MeterSnapshotBook", esp_books.MeterSnapshotBook, steps,
                                 "STATUS_ESP_METER_SNAPSHOT_FILE")
        self.assertIn(b'"lilygo"', out)

    def test_device_map_null_cases(self):
        # jq: null + {..} is an object - a "null" payload or file is accepted.
        steps = [[(b"wmbus/lilygo/meters", b"null")], [(b"wmbus/heltec/meters", b" null ")],
                 [(b"wmbus/x/meters", b"true"), (b"wmbus/x/meters", b'"s"')]]
        self.compare_steps("MetersBook", esp_books.MetersBook, steps, "STATUS_ESP_METERS_FILE")
        for seed in (b"null", b"null\n{}"):
            with self.subTest(seed=seed):
                self.compare_steps("MetersBook", esp_books.MetersBook,
                                   [[(b"wmbus/a/meters", b'{"t":1}')]], "STATUS_ESP_METERS_FILE", seed=seed)

    def test_summary(self):
        steps = [
            [(b"wmbus/lilygo/diag/summary", b'{"event":"summary","interval_s":60,"total":17,"ok":16}')],
            [(b"wmbus/heltec/diag/summary", b'{"total":3}{"total":4}')],
            [(b"wmbus/x/diag/summary", b"not json")],
            [(b"wmbus/x/diag/summary", b'{"a":1} junk')],
            [(b"wmbus/x/diag/summary", b"   ")],
            [(b"wmbus/y/diag/summary", b"null")],
            [(b"wmbus/y/diag/summary", b'{"a":1} 5')],
            [(b"wmbus/z/diag/summary", b'{"multi":1}\n{"line":2}')],
            [(b"\twmbus/t/diag/summary", b'\t{"total":9}')],
        ]
        self.compare_steps("SummaryBook", esp_books.SummaryBook, steps, "STATUS_ESP_DIAG_FILE")

    def test_meter_window(self):
        w = lambda mid: ('{"id":%s,"mode":"T1","count_window":5,"avg_interval_s":60,"elapsed_s":300}'  # noqa: E731
                         % mid).encode()
        steps = [
            [(b"wmbus/lilygo/diag/meter/03534159/T1/window/count", w('"03534159"'))],
            [(b"wmbus/lilygo/diag/meter/00089907/T1/window/count", w('"00089907"')),
             (b"wmbus/heltec/diag/meter/03534159/T1/window/time", w('"03534159"')),
             (b"wmbus/lilygo/diag/meter/03534159/T1/window/count", w('"03534159"'))],
            [(b"wmbus/x/diag/meter/1/T1/window/c", b'{"mode":"T1"}'),
             (b"wmbus/x/diag/meter/1/T1/window/c", w("12345678")),
             (b"wmbus/x/diag/meter/1/T1/window/c", w('""')),
             (b"wmbus/x/diag/meter/1/T1/window/c", b"null"),
             (b"wmbus/x/diag/meter/1/T1/window/c", b"[1]"),
             (b"wmbus/diag/meter/1/T1/window/c", w('"aa"')),
             (b"wmbus/a/b/diag/meter/1/diag/meter/2/window/c", w('"bb"'))],
        ]
        self.compare_steps("MeterWindowBook", esp_books.MeterWindowBook, steps, "STATUS_ESP_METER_WINDOW_FILE")
        for seed in (b'{"lilygo":5}', b'{"lilygo":null}', b"[1]", b"null"):
            with self.subTest(seed=seed):
                self.compare_steps("MeterWindowBook", esp_books.MeterWindowBook,
                                   [[(b"wmbus/lilygo/diag/meter/1/T1/window/c", w('"03534159"'))]],
                                   "STATUS_ESP_METER_WINDOW_FILE", seed=seed)

    def diag_compare(self, steps, seeds=None, history=True):
        """The diag events loop against DiagEventsBook. steps: lists of
        (retained, topic, payload); a step is one run of the loop (bash
        restarts its subshell, so the book is new as well)."""
        names = ("events", "suggestion", "boot", "config", "history")
        sides = {}
        for side in ("bash", "py"):
            d = os.path.join(self.tmp, side)
            os.makedirs(d)
            sides[side] = {n: os.path.join(d, n) for n in names}
            for n, data in (seeds or {"events": b"", "config": b""}).items():
                Path(sides[side][n]).write_bytes(data)
        helpers = "\n".join([shell_function(LIB, "_esp_boot_is_new"), shell_function(LIB, "_esp_diag_replay_ignored"),
                             shell_function(TSV_LIB, "_append_esp_diag_history"),
                             shell_function(TSV_LIB, "_trim_esp_rx_history")])
        block = helpers + "\n" + loop_block("DiagEventsBook")
        b, p = sides["bash"], sides["py"]
        for n, messages in enumerate(steps):
            corpus = b"".join(r + b"\t" + t + b"\t" + pl + b"\n" for r, t, pl in messages)
            run_bash(block, corpus, {
                "STATUS_ESP_EVENTS_FILE": b["events"], "STATUS_ESP_SUGGESTION_FILE": b["suggestion"],
                "STATUS_ESP_BOOT_FILE": b["boot"], "STATUS_ESP_CONFIG_FILE": b["config"],
                "ESP_DIAG_HISTORY_FILE": b["history"],
                "ESP_DIAG_HISTORY_ENABLED": "true" if history else "false"})
            if history:
                bl.trim_locked(p["history"], 10000, 9000)  # bash does it at start (books mode too)
            book = esp_books.DiagEventsBook(p["events"], p["suggestion"], p["boot"], p["config"],
                                            p["history"], history)
            deliver = mp._deliver_lines(book, "test", with_retained=True)
            for r, t, pl in messages:
                deliver(t, pl, r == b"1")
            for name in names:
                self.assertEqual(read(p[name]), read(b[name]), f"{name} after step {n}")
        return {name: read(p[name]) for name in names}

    def test_diag_events(self):
        boot = b'{"event":"boot","uptime_s":3,"reason":"power"}'
        fifo = b'{"schema":1,"kind":"fifo_sample","len":3,"hex":"aabbcc"}'
        steps = [
            [(b"1", b"wmbus/lilygo/diag/config", b'{"mode":"T1","chip":"SX1276"}'),
             (b"0", b"wmbus/heltec/diag/config", b'{"mode":"C1"}'),
             (b"1", b"wmbus/lilygo/diag/boot", boot),
             (b"0", b"wmbus/lilygo/diag", b'{"event":"suggestion","text":"move the antenna"}'),
             (b"0", b"wmbus/lilygo/diag/boot", boot),
             (b"0", b"wmbus/lilygo/diag", boot),
             (b"0", b"wmbus/heltec/diag", b'{"event":"suggestion","text":"x"}'),
             (b"0", b"wmbus/lilygo/diag/summary_15min", b'{"event":"summary","total":3}'),
             (b"0", b"wmbus/lilygo/diag/summary_60min", b'{"event":"summary","total":9}'),
             (b"0", b"wmbus/lilygo/diag/lr_fifo/1", fifo),
             (b"0", b"wmbus/lilygo/diag/lr_drop/2", b'{"schema":1.0,"kind":"pipeline_drop","topic":"old"}'),
             (b"0", b"wmbus/lilygo/diag/lr_fifo/3", b'{"schema":true,"kind":"fifo_sample"}'),
             (b"0", b"wmbus/lilygo/diag/lr_fifo/4", b'{"schema":1,"kind":"other"}'),
             (b"0", b"wmbus/lilygo/diag/lr_fifo/5", fifo + b" [1]"),
             (b"0", b"wmbus/lilygo/diag/lr_fifo/6", fifo + b" null " + fifo),
             (b"0", b"wmbus/lilygo/diag/lr_fifo/7", fifo + b" junk"),
             (b"1", b"wmbus/lilygo/diag/lr_fifo/8", fifo)],
            [(b"0", b"wmbus/x/diag", e) for e in (
                b'{"event":5}', b'{"event":1.50}', b'{"event":{"a":[1,{"b":null}]}}', b'{"event":null}',
                b'{"event":false}', b"null", b"5", b"[1]", b'"str"', b'{"event":"a"}{"event":"b"}',
                b'{"event":"a"} junk', b"   ", b'{"event":"null"}', b'{"event":""}', b'{"event":"x\\ny"}',
                b'\t{"event":"tabs"}\t', b'{"event":"t"}\t\tinner', b"not json",
                b'{"event":"m"}\n0\twmbus/z/diag\t{"event":"injected"}', b'{"event":"m"}\n1\twmbus/z/diag\tx',
                b'{"event":"suggestion"} 5', b'{"event":"suggestion"}{"event":"suggestion"}',
                b'{"event":"suggestion\\n"}', "zażółć".encode())]
            + [(b"0", b"wmbus/x/diag", b""), (b"0", b"", b'{"event":"no topic"}'),
               (b"0", b"other/x/diag", b'{"event":"elsewhere"}'),
               (b"0", b"wmbus/diag/config", b'{"a":1}'), (b"0", b"wmbus//diag/config", b'{"a":1}'),
               (b"0", b"wmbus/a/b/diag/config", b'{"deep":1}'), (b"0", b"wmbus/bad/diag/config", b"junk"),
               (b"0", b"wmbus/arr/diag/config", b"[1]"), (b"0", b"wmbus/nul/diag/config", b"null"),
               (b"0", b"wmbus/two/diag/config", b'{"a":1} {"b":2}')],
            # A new run of the loop: the boot is new to it again.
            [(b"0", b"wmbus/lilygo/diag/boot", boot),
             (b"0", b"wmbus/lilygo/diag/boot", b'{"event":"boot","uptime_s":4}'),
             (b"0", b"wmbus/q/diag", b'{"event":"boot"} junk'),
             (b"0", b"wmbus/q/diag", b'{"event":"suggestion","n":1}')],
            # A restart drops the suggestion kept from before it.
            [(b"0", b"wmbus/q/diag/boot", b'{"event":"boot","uptime_s":1}')],
        ]
        out = self.diag_compare(steps)
        self.assertIsNone(out["suggestion"])
        self.assertIn(b"\tsummary_15min\twmbus/lilygo/diag/summary_15min\t", out["events"])
        self.assertIn(b'"heltec"', out["config"])
        self.assertIn(b'"bridge_rx_time":%d' % NOW, out["history"])
        self.assertIsNotNone(out["boot"])

    def test_diag_events_rolls_and_trims(self):
        fifo = b'{"schema":1,"kind":"fifo_sample","n":%d}'
        seeds = {"events": b"".join(b"%d\told\twmbus/a/diag\t{}\n" % i for i in range(240)),
                 "config": b"", "history": b"".join(b'{"old":%d}\n' % i for i in range(10050))}
        steps = [[(b"0", b"wmbus/a/diag/lr_fifo/%d" % i, fifo % i) for i in range(101)]]
        out = self.diag_compare(steps, seeds)
        self.assertEqual(out["events"].count(b"\n"), 201)  # cut to 200 at the 50th and 100th row

    def test_diag_events_config_seeds(self):
        steps = [[(b"1", b"wmbus/lilygo/diag/config", b'{"mode":"T1"}')]]
        for seed in (b"\n", b"\n\n", b"   ", b"[1]", b"garbage", b'{"a":1}\n{"b":2}\n', b"null"):
            with self.subTest(seed=seed):
                self.tmp = tempfile.mkdtemp()
                self.diag_compare(steps, {"events": b"", "config": seed}, history=False)

    def test_broker_info(self):
        # One run of the loop each: its three values start empty, like a new book.
        runs = [
            [(b"$SYS/broker/version", b"mosquitto version 2.0.18"),
             (b"$SYS/broker/clients/connected", b"12")],
            [(b"$SYS/brokers/emqx@127.0.0.1/sysdescr", b"EMQX"),
             (b"$SYS/brokers/emqx@127.0.0.1/version", b"5.8.6"),
             (b"$SYS/brokers/emqx@127.0.0.1/clients/count", b"clients: 7")],
            [(b"$SYS/brokers/emqx@127.0.0.1/clients/count", b"40")],
            [(b"$SYS/broker/version", b"version 1 version 2")],
            [(b"$SYS/broker/version", b"no marker")],
            # Nothing known yet and only a count without digits: no file.
            [(b"$SYS/broker/clients/connected", b"n/a")],
            [(b"$SYS/brokers//version", b"x"), (b"$SYS/brokers/version", b"y"),
             (b"$SYS/brokers/a/b/sysdescr", b"deep"), (b"$SYS/other", b"z"),
             (b"$SYS/broker/version", b""), (b"$SYS/broker/clients/connected", b"n/a"),
             (b"\t$SYS/broker/clients/connected", b"\t3\t")],
            [(b"$SYS/broker/version", b"mosquitto version 2\nsecond line"),
             (b"$SYS/broker/clients/connected", "zażółć 5".encode())],
            [(b"$SYS/other", b"only noise")],
        ]
        for n, messages in enumerate(runs):
            with self.subTest(run=n):
                self.tmp = tempfile.mkdtemp()
                self.compare_steps("BrokerInfoBook", esp_books.BrokerInfoBook, [messages],
                                   "STATUS_BROKER_INFO_FILE")

    def test_ha_presence(self):
        steps = [
            [(b"homeassistant/status", b"online")],
            [(b"homeassistant/status", b" OFFLINE ")],
            [(b"homeassistant/status", b"unknown"), (b"homeassistant/status", b"")],
            [(b"homeassistant/status", b"on line"), (b"homeassistant/status", b"Online\noffline\nx")],
        ]
        out = self.compare_steps("HaPresenceBook", esp_books.HaPresenceBook, steps,
                                 "STATUS_HA_PRESENCE_FILE", payload_only=True)
        self.assertEqual(out, b"offline\t%d\n" % NOW)


if __name__ == "__main__":
    unittest.main()
