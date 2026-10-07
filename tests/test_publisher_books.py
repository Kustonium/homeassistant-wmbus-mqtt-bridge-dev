"""The ESP subscriptions run inside mqtt_publisher.py (rssi, /rx, RAW tracker).

1. Equivalence: a book fed by the publisher's delivery (_deliver_lines) writes
   the same files, byte for byte, as the same book fed by bridge_ledger.run()
   from what `mosquitto_sub -F '%t\\t%p'` prints - the path these
   subscriptions took before.
2. End to end: the publisher subscribes on its own broker connection,
   announces "books", books live messages, and drops retained ones where the
   bash loop passed mosquitto_sub -R.
"""
from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "rootfs" / "usr" / "bin"))
sys.path.insert(0, str(ROOT / "tests" / "helpers"))

import bridge_ledger as bl  # noqa: E402
import mqtt_publisher as mp  # noqa: E402
from fake_mqtt_broker import FakeBroker  # noqa: E402

PUBLISHER = ROOT / "rootfs" / "usr" / "bin" / "mqtt_publisher.py"
QWATER = (ROOT / "tests" / "fixtures" / "qwaterv2" / "52632878.hex").read_text().split()[0]
RX_BASE = ('"schema":1,"rx_task_wakeup_us":123,"mode":"T1","frame_crc32":"7f56a83c",'
           '"frame_length":123')


def rx(seq, meter, extra=""):
    return ('{%s,"boot_id":"a84f12c7","seq":%d,"meter_id":"%s"%s}' % (RX_BASE, seq, meter, extra)).encode()


MESSAGES = {
    "rssi": [(b"wmbus/lilygo/rssi/52632878", b"-61"), (b"wmbus/xiao-seed/rssi/52632878", b"-70"),
             (b"wmbus/lilygo/rssi/99999999", b"-50"), (b"wmbus/lilygo/rssi/52632878", b"-1"),
             (b"wmbus/lilygo/rssi/52632878", b"-127"), (b"wmbus/lilygo/rssi/abcdef12", b"-80"),
             (b"wmbus/lilygo/rssi/52632878", b"-62\n-63")],
    "rx": [(b"wmbus/lilygo/rx", rx(1, "52632878", ',"rssi_dbm":-54,"received_at":"2026-10-02T10:00:00.123Z"')),
           (b"wmbus/lilygo/rx", rx(2, "52632878")), (b"wmbus/heltec/rx", rx(7, "77665544")),
           (b"wmbus/lilygo/rx", b"not json"), (b"wmbus/lilygo/rx", b"")],
    "tracker": [(b"wmbus/lilygo/telegram", QWATER.encode()), (b"wmbus/heltec/telegram", QWATER.encode()),
                (b"wmbus/lilygo/telegram", b"zz"), (b"wmbus/lilygo/telegram", QWATER.encode())],
}


def make(mode, d):
    p = lambda name: os.path.join(d, name)  # noqa: E731
    os.makedirs(d, exist_ok=True)
    if mode == "tracker":
        # bridge.sh creates these at start; the tracker only updates them.
        for name in ("devices", "meter_device"):
            Path(p(name)).touch()
    if mode == "rssi":
        os.makedirs(p("meters"), exist_ok=True)
        Path(p("meters/meter-0001")).write_text("name=water\nid=52632878\ndriver=auto\n")
        Path(p("meters/meter-0002")).write_text("id=abcdef12\n")
        return bl.RssiBook(p("meters"), p("status_rssi.tsv")), {
            "filter": "wmbus/+/rssi/+", "meter_dir": p("meters"), "rssi_file": p("status_rssi.tsv")}
    if mode == "rx":
        names = ("reception", "mode", "history", "sequence", "boots", "clock")
        return bl.RxBook(*(p(n) for n in names)), dict(
            {"filter": "wmbus/+/rx", "no_retained": True}, **{f"{n}_file": p(n) for n in names})
    names = ("devices", "meter_device", "reception", "history")
    return bl.TrackerBook(1, *(p(n) for n in names)), dict(
        {"filter": "wmbus/+/telegram", "no_retained": True, "dev_pos": 1}, **{f"{n}_file": p(n) for n in names})


def files(d):
    out = {}
    for root, _, names in os.walk(d):
        for n in names:
            path = os.path.join(root, n)
            out[os.path.relpath(path, d)] = Path(path).read_bytes()
    return out


class EquivalenceTests(unittest.TestCase):
    def setUp(self):
        self._now = bl.now
        bl.now = lambda: 1790000000.0

    def tearDown(self):
        bl.now = self._now

    def test_same_files_as_bridge_ledger_run(self):
        for mode, messages in MESSAGES.items():
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
                book_a, _ = make(mode, a)
                stream = io.BytesIO(b"".join(t + b"\t" + p + b"\n" for t, p in messages))
                bl.run(book_a, stream=stream, err=io.StringIO())
                book_b, _ = make(mode, b)
                deliver = mp._deliver_lines(book_b, mode)
                for t, p in messages:
                    deliver(t, p)
                if getattr(book_b, "deferred", None) is not None:
                    book_b.deferred.flush()
                fa, fb = files(a), files(b)
                self.assertTrue(any(v for k, v in fa.items() if not k.startswith("meters")),
                                f"{mode}: the corpus books nothing")
                self.assertEqual(fa, fb, mode)


class TopicMatchTests(unittest.TestCase):
    def test_filters(self):
        m = mp.topic_matches
        self.assertTrue(m(b"wmbus/+/rx", b"wmbus/lilygo/rx"))
        self.assertFalse(m(b"wmbus/+/rx", b"wmbus/lilygo/rx/x"))
        self.assertTrue(m(b"wmbus/+/rssi/+", b"wmbus/a/rssi/1"))
        self.assertTrue(m(b"wmbus/#", b"wmbus/a/b/c"))
        self.assertFalse(m(b"#", b"$SYS/broker/version"))
        self.assertTrue(m(b"$SYS/broker/version", b"$SYS/broker/version"))

    def test_filter_covers(self):
        c = mp.filter_covers
        self.assertTrue(c(b"wmbus/+/diag/#", b"wmbus/+/diag"))
        self.assertTrue(c(b"wmbus/+/diag/#", b"wmbus/+/diag/summary"))
        self.assertTrue(c(b"wmbus/+/diag/#", b"wmbus/+/diag/meter/+/+/window/+"))
        self.assertTrue(c(b"wmbus/+/diag/#", b"wmbus/x/diag/a/#"))
        self.assertFalse(c(b"wmbus/+/diag/#", b"wmbus/+/health"))
        self.assertFalse(c(b"wmbus/+/diag", b"wmbus/+/diag/#"))
        self.assertFalse(c(b"wmbus/x/diag/#", b"wmbus/+/diag"))
        self.assertFalse(c(b"wmbus/+/rssi/+", b"wmbus/+/rssi/#"))
        self.assertFalse(c(b"#", b"$SYS/broker/version"))
        self.assertFalse(c(b"+/broker/version", b"$SYS/broker/version"))
        self.assertTrue(c(b"#", b"homeassistant/status"))


class EndToEndTests(unittest.TestCase):
    def test_publisher_books_live_messages(self):
        broker = FakeBroker()
        # Overlapping filters (wmbus/+/diag/# and .../diag/summary) must not
        # book a message twice even where the broker sends a copy per filter.
        broker.copy_per_subscription = True
        tmp = tempfile.mkdtemp()
        spec = {}
        for mode in MESSAGES:
            _, cfg = make(mode, os.path.join(tmp, mode))
            spec[mode] = cfg
        health_file = os.path.join(tmp, "status_esp_health.json")
        presence_file = os.path.join(tmp, "status_ha_presence.txt")
        spec["health"] = {"filter": "wmbus/+/health", "health_file": health_file}
        spec["ha_presence"] = {"filter": "homeassistant/status", "format": "payload",
                               "presence_file": presence_file}
        window_file = os.path.join(tmp, "status_esp_meter_window.json")
        spec["meters"] = {"filter": "wmbus/+/meters", "file": os.path.join(tmp, "status_esp_meters.json")}
        spec["meter_snapshot"] = {"filter": "wmbus/+/diag/meter_snapshot",
                                  "file": os.path.join(tmp, "status_esp_meter_snapshot.json")}
        spec["summary"] = {"filter": "wmbus/+/diag/summary", "file": os.path.join(tmp, "status_esp_diag.json")}
        spec["meter_window"] = {"filter": "wmbus/+/diag/meter/+/+/window/+", "file": window_file}
        events_file = os.path.join(tmp, "status_esp_events.tsv")
        config_file = os.path.join(tmp, "status_esp_config.json")
        spec["diag_events"] = {"filter": "wmbus/+/diag/#", "format": "retained", "events_file": events_file,
                               "suggestion_file": os.path.join(tmp, "suggestion.json"),
                               "boot_file": os.path.join(tmp, "boot.json"), "config_file": config_file}
        # Retained: the settings are learned from it, the event log skips it.
        broker.publish_to_subscribers("wmbus/lilygo/diag/config", b'{"mode":"T1"}', retain=True)
        # HA's birth message is retained: the subscription must replay it.
        broker.publish_to_subscribers("homeassistant/status", b"online", retain=True)
        # Retained before the publisher subscribes: replayed on SUBSCRIBE with
        # the retain flag; rssi keeps it, /rx and RAW drop it (mosquitto_sub -R).
        broker.publish_to_subscribers("wmbus/old/rssi/52632878", b"-90", retain=True)
        broker.publish_to_subscribers("wmbus/old/rx", rx(9, "52632878"), retain=True)
        port_file = os.path.join(tmp, "publisher.port")
        env = dict(os.environ, MQTT_PUBLISHER_BOOKS=json.dumps(spec))
        proc = subprocess.Popen([sys.executable, str(PUBLISHER), "--host", "127.0.0.1",
                                 "--port", str(broker.port), "--port-file", port_file],
                                env=env, stderr=subprocess.PIPE, text=True)
        try:
            self.assertTrue(broker.wait_for(lambda b: len(b.subscribes) >= 7, timeout=10),
                            "the publisher did not subscribe")
            self.assertIn("books", Path(port_file).read_text().split()[1:])
            # wmbus/+/diag/# covers the summary, snapshot and window filters.
            self.assertEqual(sorted(broker.subscribes),
                             [b"homeassistant/status", b"wmbus/+/diag/#", b"wmbus/+/health",
                              b"wmbus/+/meters", b"wmbus/+/rssi/+", b"wmbus/+/rx", b"wmbus/+/telegram"])
            broker.publish_to_subscribers("wmbus/lilygo/diag/summary", b'{"event":"summary","total":5}')
            broker.publish_to_subscribers("wmbus/lilygo/diag", b'{"event":"dropped","n":1}')
            broker.publish_to_subscribers("wmbus/lilygo/diag/meter/03534159/T1/window/count",
                                          b'{"id":"03534159","count_window":3}')
            for mode, messages in MESSAGES.items():
                for t, p in messages:
                    broker.publish_to_subscribers(t, p)
            broker.publish_to_subscribers("wmbus/lilygo/health", b'{"uptime_s":5}')
            deadline = time.time() + 10
            while time.time() < deadline and not (os.path.exists(health_file) and os.path.exists(presence_file)):
                time.sleep(0.1)
            self.assertIn('"lilygo": {', Path(health_file).read_text())
            self.assertIn('"03534159": {', Path(window_file).read_text())
            self.assertIn('"total": 5', Path(spec["summary"]["file"]).read_text())
            self.assertIn('"lilygo": {', Path(config_file).read_text())
            events = Path(events_file).read_text().splitlines()
            self.assertEqual([e.split("	")[1:3] for e in events],
                             [["summary", "wmbus/lilygo/diag/summary"], ["dropped", "wmbus/lilygo/diag"],
                              ["unknown", "wmbus/lilygo/diag/meter/03534159/T1/window/count"]],
                             "each diag message is one row (as in the bash loop, which also saw"
                             " the window topics); the retained config none")
            self.assertTrue(Path(presence_file).read_text().startswith("online\t"),
                            "the retained HA birth message is booked")
            deadline = time.time() + 15  # /rx and the tracker write every 5 s
            want = [os.path.join(tmp, "rssi", "status_rssi.tsv"), os.path.join(tmp, "rx", "reception"),
                    os.path.join(tmp, "tracker", "devices")]
            while time.time() < deadline and not all(os.path.exists(w) for w in want):
                time.sleep(0.2)
            rssi = Path(want[0]).read_text()
            self.assertIn("52632878\t-90\told\t", rssi, "a retained rssi message is booked (no -R)")
            self.assertIn("52632878\t-62\tlilygo\t", rssi)
            self.assertNotIn("99999999", rssi)
            self.assertNotIn("\told\t", Path(want[1]).read_text(), "retained /rx must be dropped (-R)")
            self.assertIn("lilygo", Path(want[1]).read_text())
            self.assertIn("heltec", Path(want[2]).read_text())
            self.assertEqual(len(broker.connects), 1, "one broker connection for all")
        finally:
            proc.terminate()
            err = proc.communicate(timeout=10)[1]
            broker.close()
        self.assertNotIn("skipped", err, err)


if __name__ == "__main__":
    unittest.main()
