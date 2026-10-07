#!/usr/bin/env python3
"""A minimal MQTT 3.1.1 broker for tests: it accepts clients, answers CONNECT
and PINGREQ, and records every PUBLISH.

Used by tests/test_mqtt_publisher.py (in-process, FakeBroker) and by
tests/test_publish_contract.sh (as a process: `fake_mqtt_broker.py PORT_FILE
OUT_TSV`, which writes one "<topic>\\t<retain true|false>\\t<payload>" line per
message and the port it listens on to PORT_FILE).
"""

import os
import socket
import struct
import sys
import threading


def _read_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("closed")
        buf += chunk
    return buf


def read_packet(sock):
    first = _read_exact(sock, 1)[0]
    mult, length = 1, 0
    while True:
        byte = _read_exact(sock, 1)[0]
        length += (byte & 0x7F) * mult
        if not byte & 0x80:
            break
        mult *= 128
    return first, _read_exact(sock, length) if length else b""


def _string(body, pos):
    n = struct.unpack("!H", body[pos:pos + 2])[0]
    return body[pos + 2:pos + 2 + n], pos + 2 + n


def topic_matches(flt, topic):
    if topic.startswith(b"$") and flt[:1] in (b"+", b"#"):
        return False
    fp, tp = flt.split(b"/"), topic.split(b"/")
    for i, part in enumerate(fp):
        if part == b"#":
            return True
        if i >= len(tp) or (part != b"+" and part != tp[i]):
            return False
    return len(fp) == len(tp)


def parse_connect(body):
    name, pos = _string(body, 0)
    level, flags = body[pos], body[pos + 1]
    keepalive = struct.unpack("!H", body[pos + 2:pos + 4])[0]
    pos += 4
    client_id, pos = _string(body, pos)
    user = password = None
    if flags & 0x80:
        user, pos = _string(body, pos)
    if flags & 0x40:
        password, pos = _string(body, pos)
    return {"protocol": name, "level": level, "flags": flags, "keepalive": keepalive,
            "client_id": client_id.decode(), "user": user, "password": password}


class FakeBroker:
    """In-process broker. connack_rc != 0 refuses every client."""

    def __init__(self, port=0, connack_rc=0, on_publish=None):
        self.srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.srv.bind(("127.0.0.1", port))
        self.srv.listen(16)
        self.port = self.srv.getsockname()[1]
        self.connack_rc = connack_rc
        self.on_publish = on_publish
        self.connects = []
        self.messages = []  # (topic, retain, payload)
        self.pings = 0
        self.clients = []
        self.subs = {}       # conn -> [filter bytes], for routing
        self.retained = {}   # topic bytes -> payload
        self.subscribes = []  # [filter bytes] of every SUBSCRIBE received
        self.refuse = set()   # filters answered with 0x80 (as EMQX's ACL does for $SYS)
        # One copy per matching subscription instead of one per client, which
        # MQTT 3.1.1 also allows for overlapping subscriptions.
        self.copy_per_subscription = False
        # Close the connection instead of answering a refused SUBSCRIBE (an
        # EMQX authorization deny_action of "disconnect").
        self.disconnect_on_refuse = False
        self.lock = threading.Lock()
        self.cond = threading.Condition(self.lock)
        self.closed = False
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self):
        while not self.closed:
            try:
                conn, _ = self.srv.accept()
            except OSError:
                return
            with self.lock:
                self.clients.append(conn)
            threading.Thread(target=self._serve, args=(conn,), daemon=True).start()

    def _serve(self, conn):
        try:
            while True:
                ptype, body = read_packet(conn)
                kind = ptype >> 4
                if kind == 1:
                    with self.cond:
                        self.connects.append(parse_connect(body))
                        self.cond.notify_all()
                    conn.sendall(bytes([0x20, 0x02, 0x00, self.connack_rc]))
                    if self.connack_rc:
                        conn.close()
                        return
                elif kind == 3:
                    topic, pos = _string(body, 0)
                    if (ptype >> 1) & 0x03:
                        pos += 2  # packet id of QoS 1/2 (not used by the add-on)
                    msg = (topic.decode(), bool(ptype & 0x01), body[pos:])
                    with self.cond:
                        self.messages.append(msg)
                        if msg[1]:
                            if msg[2]:
                                self.retained[topic] = msg[2]
                            else:
                                self.retained.pop(topic, None)
                        targets = [c for c, flts in self.subs.items()
                                   if any(topic_matches(f, topic) for f in flts)]
                        self.cond.notify_all()
                    for c in targets:  # forwarded live: retain flag cleared
                        self._send_publish(c, topic, msg[2], False)
                    if self.on_publish:
                        self.on_publish(*msg)
                elif kind == 8:  # SUBSCRIBE
                    pid, pos, flts, codes = body[:2], 2, [], b""
                    while pos < len(body):
                        flt, pos = _string(body, pos)
                        pos += 1  # requested QoS
                        flts.append(flt)
                        codes += b"\x80" if flt in self.refuse else b"\x00"
                    with self.cond:
                        self.subscribes.extend(flts)
                        if self.disconnect_on_refuse and any(f in self.refuse for f in flts):
                            self.cond.notify_all()
                            conn.close()
                            return
                        self.subs.setdefault(conn, []).extend(f for f in flts if f not in self.refuse)
                        replay = [(t, p) for t, p in self.retained.items()
                                  if any(topic_matches(f, t) for f in flts if f not in self.refuse)]
                        self.cond.notify_all()
                    conn.sendall(bytes([0x90, 2 + len(codes)]) + pid + codes)
                    for t, p in replay:
                        self._send_publish(conn, t, p, True)
                elif kind == 12:
                    with self.cond:
                        self.pings += 1
                    conn.sendall(b"\xd0\x00")
                elif kind == 14:
                    conn.close()
                    return
        except (ConnectionError, OSError):
            pass

    @staticmethod
    def _send_publish(conn, topic, payload, retain):
        body = struct.pack("!H", len(topic)) + topic + payload
        n, rl = len(body), bytearray()
        while True:
            b, n = n % 128, n // 128
            rl.append(b | (0x80 if n else 0))
            if not n:
                break
        try:
            conn.sendall(bytes([0x30 | (1 if retain else 0)]) + bytes(rl) + body)
        except OSError:
            pass

    def publish_to_subscribers(self, topic, payload, retain=False):
        """Act as another client publishing (an ESP board)."""
        topic = topic.encode() if isinstance(topic, str) else topic
        with self.cond:
            if retain:
                self.retained[topic] = payload
            targets = [c for c, flts in self.subs.items()
                       for _ in range(sum(topic_matches(f, topic) for f in flts)
                                      if self.copy_per_subscription else
                                      any(topic_matches(f, topic) for f in flts))]
        for c in targets:
            self._send_publish(c, topic, payload, False)

    def drop_clients(self):
        """Cut every client connection, as a broker restart would."""
        with self.lock:
            clients, self.clients = self.clients, []
            self.subs = {}
        for c in clients:
            try:
                c.shutdown(socket.SHUT_RDWR)
                c.close()
            except OSError:
                pass

    def wait_for(self, predicate, timeout=10.0):
        with self.cond:
            return self.cond.wait_for(lambda: predicate(self), timeout)

    def close(self):
        self.closed = True
        self.drop_clients()
        self.srv.close()


def main(argv):
    port_file, out = argv[1], argv[2]
    fh = open(out, "a", encoding="utf-8", newline="\n")
    lock = threading.Lock()

    def record(topic, retain, payload):
        with lock:
            fh.write("%s\t%s\t%s\n" % (topic, "true" if retain else "false",
                                       payload.decode("utf-8", "surrogateescape")))
            fh.flush()

    broker = FakeBroker(on_publish=record)
    with open(port_file + ".tmp", "w", encoding="ascii") as pf:
        pf.write("%d\n" % broker.port)
    os.replace(port_file + ".tmp", port_file)
    threading.Event().wait()


if __name__ == "__main__":
    main(sys.argv)
