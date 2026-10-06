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
                        self.cond.notify_all()
                    if self.on_publish:
                        self.on_publish(*msg)
                elif kind == 12:
                    with self.cond:
                        self.pings += 1
                    conn.sendall(b"\xd0\x00")
                elif kind == 14:
                    conn.close()
                    return
        except (ConnectionError, OSError):
            pass

    def drop_clients(self):
        """Cut every client connection, as a broker restart would."""
        with self.lock:
            clients, self.clients = self.clients, []
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
