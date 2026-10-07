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
NOW = 1790000000


def loop_block(marker: str) -> str:
    """The `( ... ) &` subscriber block guarded by the comment naming marker."""
    lines = LIB.read_text(encoding="utf-8").replace("\r\n", "\n").split("\n")
    start = next(i for i, l in enumerate(lines) if f"(esp_books.{marker})" in l)
    begin = next(i for i in range(start, len(lines)) if lines[i] == "(")
    end = next(i for i in range(begin, len(lines)) if lines[i] == ") &")
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
