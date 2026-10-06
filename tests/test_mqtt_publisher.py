"""Tests for mqtt_publisher.py: the frame format bash writes, the MQTT packets
it sends, and its behaviour against a broker that is up, down, restarted or
refusing (tests/helpers/fake_mqtt_broker.py).
"""
from __future__ import annotations

import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "rootfs" / "usr" / "bin"))
sys.path.insert(0, str(ROOT / "tests" / "helpers"))

import mqtt_publisher as mp  # noqa: E402
from fake_mqtt_broker import FakeBroker  # noqa: E402

PUBLISHER = ROOT / "rootfs" / "usr" / "bin" / "mqtt_publisher.py"


def frame(topic, payload, retain=False):
    if isinstance(payload, str):
        payload = payload.encode()
    return b"PUB %d %d %s\n%s\n" % (1 if retain else 0, len(payload), topic.encode(), payload)


class FrameTests(unittest.TestCase):
    def test_complete_frames_in_order(self):
        data = frame("a/b", '{"x":1}', True) + frame("c", "", False)
        msg, rest = mp.parse_frame(data)
        self.assertEqual(msg, (b"a/b", b'{"x":1}', True))
        msg, rest = mp.parse_frame(rest)
        self.assertEqual(msg, (b"c", b"", False))
        self.assertEqual(rest, b"")

    def test_partial_frame_waits(self):
        data = frame("t", "0123456789")
        for cut in (3, data.index(b"\n"), len(data) - 1):
            msg, rest = mp.parse_frame(data[:cut])
            self.assertIsNone(msg)
            self.assertEqual(rest, data[:cut])

    def test_payload_with_newlines_and_utf8(self):
        payload = "zażółć\ngęślą\n".encode()
        msg, rest = mp.parse_frame(frame("t/ł", payload))
        self.assertEqual(msg, ("t/ł".encode(), payload, False))
        self.assertEqual(rest, b"")

    def test_topic_with_spaces(self):
        msg, _ = mp.parse_frame(frame("a b/c d", "v"))
        self.assertEqual(msg[0], b"a b/c d")

    def test_malformed(self):
        for bad in (b"PUT 0 1 t\nx\n", b"PUB 2 1 t\nx\n", b"PUB 0 x t\nx\n",
                    b"PUB 0 1 \nx\n", b"PUB 0 1 t\nxy\n", b"PUB 0 -1 t\n\n"):
            with self.assertRaises(ValueError, msg=bad):
                mp.parse_frame(bad)


class PacketTests(unittest.TestCase):
    def test_remaining_length_boundaries(self):
        # MQTT 3.1.1 section 2.2.3
        cases = {0: b"\x00", 127: b"\x7f", 128: b"\x80\x01", 16383: b"\xff\x7f",
                 16384: b"\x80\x80\x01", 2097151: b"\xff\xff\x7f"}
        for n, enc in cases.items():
            self.assertEqual(mp._remaining_length(n), enc, n)

    def test_publish_packet(self):
        pkt = mp.publish_packet(b"a/b", b"xyz", True)
        self.assertEqual(pkt, b"\x31\x08\x00\x03a/bxyz")
        self.assertEqual(mp.publish_packet(b"t", b"", False), b"\x30\x03\x00\x01t")

    def test_connect_packet(self):
        pkt = mp.connect_packet("cid", "user", "pw")
        self.assertEqual(pkt[0], 0x10)
        body = pkt[2:]
        self.assertEqual(body[:7], b"\x00\x04MQTT\x04")
        self.assertEqual(body[7], 0x80 | 0x40 | 0x02)
        self.assertEqual(body[8:10], b"\x00\x3c")
        # no user: neither flag, even with a password
        self.assertEqual(mp.connect_packet("cid", None, "pw")[9], 0x02)


class PublisherProcess:
    """mqtt_publisher.py as the add-on runs it."""

    def __init__(self, broker_port, tmp, user=None, password=None):
        self.port_file = os.path.join(tmp, "publisher.port")
        env = dict(os.environ)
        env.pop("MQTT_USER", None)
        env.pop("MQTT_PASS", None)
        if user:
            env["MQTT_USER"] = user
        if password:
            env["MQTT_PASS"] = password
        self.proc = subprocess.Popen(
            [sys.executable, str(PUBLISHER), "--host", "127.0.0.1", "--port", str(broker_port),
             "--port-file", self.port_file],
            env=env, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                with open(self.port_file, encoding="ascii") as fh:
                    self.port = int(fh.read())
                return
            except (OSError, ValueError):
                time.sleep(0.02)
        raise AssertionError("publisher did not write its port")

    def send(self, *frames):
        """One writer connection per call, like bash's mqtt_pub."""
        with socket.create_connection(("127.0.0.1", self.port)) as s:
            s.sendall(b"".join(frames))

    def stop(self):
        self.proc.send_signal(signal.SIGTERM)
        try:
            _, err = self.proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            _, err = self.proc.communicate()
        return err


class PublisherTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.broker = None
        self.pub = None

    def tearDown(self):
        if self.pub:
            self.pub.stop()
        if self.broker:
            self.broker.close()

    def test_one_connection_order_retain_and_credentials(self):
        self.broker = FakeBroker()
        self.pub = PublisherProcess(self.broker.port, self.tmp, "addons", "secret")
        big = b"{" + b'"k":"' + b"x" * 200_000 + b'"}'
        msgs = [("homeassistant/sensor/a/config", b'{"n":"\xc5\x82"}', True),
                ("wmbusmeters/A/state", big, False),
                ("homeassistant/sensor/b/config", b"", True)]
        for i in range(30):
            msgs.append(("wmbusmeters/%d/state" % i, b"%d" % i, False))
        for topic, payload, retain in msgs:
            self.pub.send(frame(topic, payload, retain))
        self.assertTrue(self.broker.wait_for(lambda b: len(b.messages) == len(msgs)))
        self.assertEqual(self.broker.messages, [(t, r, p) for t, p, r in msgs])
        self.assertEqual(len(self.broker.connects), 1)
        c = self.broker.connects[0]
        self.assertEqual((c["protocol"], c["level"], c["keepalive"]), (b"MQTT", 4, 60))
        self.assertEqual((c["user"], c["password"]), (b"addons", b"secret"))
        self.assertTrue(c["client_id"].startswith("wmbus_bridge_pub_"))
        self.assertTrue(c["flags"] & 0x02, "clean session")

    def test_several_frames_in_one_connection(self):
        self.broker = FakeBroker()
        self.pub = PublisherProcess(self.broker.port, self.tmp)
        self.pub.send(frame("a", "1"), frame("b", "2"), frame("c", "3"))
        self.assertTrue(self.broker.wait_for(lambda b: len(b.messages) == 3))
        self.assertEqual([m[0] for m in self.broker.messages], ["a", "b", "c"])
        self.assertIsNone(self.broker.connects[0]["user"])

    def test_malformed_writer_does_not_stop_others(self):
        self.broker = FakeBroker()
        self.pub = PublisherProcess(self.broker.port, self.tmp)
        self.pub.send(b"garbage without a header\n")
        self.pub.send(frame("ok", "1"))
        self.assertTrue(self.broker.wait_for(lambda b: len(b.messages) == 1))
        self.assertEqual(self.broker.messages[0][0], "ok")

    def test_queued_while_broker_down_then_delivered_in_order(self):
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()
        self.pub = PublisherProcess(port, self.tmp)
        for i in range(5):
            self.pub.send(frame("q/%d" % i, str(i)))
        time.sleep(0.5)
        self.broker = FakeBroker(port=port)
        self.assertTrue(self.broker.wait_for(lambda b: len(b.messages) == 5, timeout=15))
        self.assertEqual([m[0] for m in self.broker.messages], ["q/%d" % i for i in range(5)])

    def test_reconnects_after_broker_drops_connection(self):
        self.broker = FakeBroker()
        self.pub = PublisherProcess(self.broker.port, self.tmp)
        self.pub.send(frame("before", "1"))
        self.assertTrue(self.broker.wait_for(lambda b: len(b.messages) == 1))
        self.broker.drop_clients()
        time.sleep(0.2)
        self.pub.send(frame("after", "2"))
        self.assertTrue(self.broker.wait_for(lambda b: any(m[0] == "after" for m in b.messages),
                                             timeout=15))
        self.assertEqual(len(self.broker.connects), 2)

    def test_refused_login_is_logged_and_retried(self):
        self.broker = FakeBroker(connack_rc=5)
        self.pub = PublisherProcess(self.broker.port, self.tmp, "u", "bad")
        self.assertTrue(self.broker.wait_for(lambda b: len(b.connects) >= 2, timeout=10))
        err = self.pub.stop()
        self.pub = None
        self.assertIn("not authorized", err)
        # One line per distinct reason, not one per attempt.
        self.assertEqual(err.count("not authorized"), 1)

    def test_restart_reuses_port(self):
        self.broker = FakeBroker()
        self.pub = PublisherProcess(self.broker.port, self.tmp)
        first = self.pub.port
        self.pub.stop()
        self.pub = PublisherProcess(self.broker.port, self.tmp)
        self.assertEqual(self.pub.port, first)

    def test_disconnects_cleanly_on_sigterm(self):
        self.broker = FakeBroker()
        self.pub = PublisherProcess(self.broker.port, self.tmp)
        self.pub.send(frame("last", "1"))
        self.assertTrue(self.broker.wait_for(lambda b: len(b.messages) == 1))
        err = self.pub.stop()
        self.assertEqual(self.pub.proc.returncode, 0, err)
        self.pub = None


if __name__ == "__main__":
    unittest.main()
