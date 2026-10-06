#!/usr/bin/env python3
"""One persistent MQTT connection for everything the add-on publishes.

Every publish used to be its own mosquitto_pub: a new process, a TCP
connection, a login and a disconnect - several a minute, each a few lines in
the broker's log. This process keeps one connection open instead.

bash hands it messages over a loopback TCP socket, which `/dev/tcp` opens
without forking (see mqtt_pub in bridge-lib/12-pipeline.sh). One message per
connection, framed so that any payload passes unchanged:

    PUB <retain 0|1> <payload length in bytes> <topic>\\n<payload>\\n

Connections are served one at a time, in the order they were opened, so the
messages of one writer keep their order.

The broker side is MQTT 3.1.1 with the same profile as mosquitto_pub had in
this add-on: QoS 0, clean session, optional user name and password, no TLS.
The client id is "wmbus_bridge_pub_<random>" - readable in the broker log,
and never shared by two instances (a shared id makes brokers drop one of them
every few seconds). While the broker is unreachable messages are kept in a
bounded queue and sent in order once it is back.
"""

import argparse
import collections
import os
import secrets
import select
import signal
import socket
import struct
import sys
import time

KEEPALIVE_S = 60
QUEUE_MAX = 2000
RECONNECT_MAX_S = 30
FRAME_MAX = 4 * 1024 * 1024


def log(msg):
    print(f"[wmbus-bridge] mqtt publisher: {msg}", file=sys.stderr, flush=True)


def _remaining_length(n):
    out = bytearray()
    while True:
        byte = n % 128
        n //= 128
        if n:
            byte |= 0x80
        out.append(byte)
        if not n:
            return bytes(out)


def _string(b):
    return struct.pack("!H", len(b)) + b


def connect_packet(client_id, username=None, password=None, keepalive=KEEPALIVE_S):
    flags = 0x02  # clean session
    payload = _string(client_id.encode())
    if username:
        flags |= 0x80
        payload += _string(username.encode())
        # MQTT 3.1.1 allows a password only together with a user name.
        if password:
            flags |= 0x40
            payload += _string(password.encode())
    variable = _string(b"MQTT") + bytes([4, flags]) + struct.pack("!H", keepalive)
    body = variable + payload
    return bytes([0x10]) + _remaining_length(len(body)) + body


def publish_packet(topic, payload, retain):
    body = _string(topic) + payload
    return bytes([0x30 | (0x01 if retain else 0)]) + _remaining_length(len(body)) + body


PINGREQ = b"\xc0\x00"
DISCONNECT = b"\xe0\x00"
CONNACK_REASONS = {
    1: "unacceptable protocol version",
    2: "client id rejected",
    3: "server unavailable",
    4: "bad user name or password",
    5: "not authorized",
}


def parse_frame(data):
    """Split one framed message off the front of data.

    Returns ((topic, payload, retain), rest), or (None, data) while the frame
    is incomplete. Raises ValueError on a malformed header.
    """
    nl = data.find(b"\n")
    if nl < 0:
        if len(data) > 4096:
            raise ValueError("header too long")
        return None, data
    parts = data[:nl].split(b" ", 3)
    if len(parts) != 4 or parts[0] != b"PUB" or parts[1] not in (b"0", b"1") or not parts[3]:
        raise ValueError("bad header %r" % data[:nl][:80])
    try:
        length = int(parts[2])
    except ValueError:
        raise ValueError("bad length %r" % parts[2][:20]) from None
    if length < 0 or length > FRAME_MAX:
        raise ValueError("bad length %d" % length)
    end = nl + 1 + length
    if len(data) < end + 1:
        return None, data
    if data[end:end + 1] != b"\n":
        raise ValueError("payload length does not match")
    return (parts[3], data[nl + 1:end], parts[1] == b"1"), data[end + 1:]


class Broker:
    """The broker connection: connect, publish, keepalive, reconnect."""

    def __init__(self, host, port, username, password, client_id):
        self.addr = (host, port)
        self.username = username
        self.password = password
        self.client_id = client_id
        self.sock = None
        self.queue = collections.deque(maxlen=QUEUE_MAX)
        self.dropped = 0
        self.next_attempt = 0.0
        self.backoff = 1.0
        self.last_sent = 0.0
        self.ping_sent = 0.0
        self.inbuf = b""
        self.last_error = ""

    def connected(self):
        return self.sock is not None

    def _fail(self, why):
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None
            log(f"connection to {self.addr[0]}:{self.addr[1]} lost ({why}), reconnecting")
        elif why != self.last_error:
            log(f"cannot connect to {self.addr[0]}:{self.addr[1]} ({why}), retrying")
        self.last_error = why
        self.inbuf = b""
        self.next_attempt = time.monotonic() + self.backoff
        self.backoff = min(self.backoff * 2, RECONNECT_MAX_S)

    def try_connect(self):
        if self.sock is not None or time.monotonic() < self.next_attempt:
            return
        sock = None
        try:
            sock = socket.create_connection(self.addr, timeout=10)
            sock.sendall(connect_packet(self.client_id, self.username, self.password))
            ack = b""
            while len(ack) < 4:
                chunk = sock.recv(4 - len(ack))
                if not chunk:
                    raise OSError("closed before CONNACK")
                ack += chunk
            if ack[0] != 0x20:
                raise OSError("unexpected reply 0x%02x" % ack[0])
            if ack[3] != 0:
                raise OSError("refused: " + CONNACK_REASONS.get(ack[3], str(ack[3])))
            sock.settimeout(10)
        except OSError as exc:
            if sock is not None:
                sock.close()
            self._fail(str(exc) or exc.__class__.__name__)
            return
        self.sock = sock
        self.backoff = 1.0
        self.last_error = ""
        self.last_sent = self.ping_sent = 0.0
        log(f"connected to {self.addr[0]}:{self.addr[1]} as {self.client_id}")
        if self.dropped:
            log(f"{self.dropped} message(s) dropped while the broker was unreachable")
            self.dropped = 0
        self.flush()

    def publish(self, topic, payload, retain):
        if len(self.queue) == self.queue.maxlen:
            self.dropped += 1
        self.queue.append(publish_packet(topic, payload, retain))
        self.flush()

    def flush(self):
        while self.sock is not None and self.queue:
            try:
                self.sock.sendall(self.queue[0])
            except OSError as exc:
                self._fail(str(exc) or "send failed")
                return
            self.queue.popleft()
            self.last_sent = time.monotonic()

    def on_readable(self):
        try:
            data = self.sock.recv(4096)
        except OSError as exc:
            self._fail(str(exc) or "receive failed")
            return
        if not data:
            self._fail("closed by broker")
            return
        # QoS 0 publishing expects nothing but PINGRESP; anything else is read
        # and ignored.
        self.inbuf += data
        if b"\xd0\x00" in self.inbuf:
            self.ping_sent = 0.0
        self.inbuf = self.inbuf[-2:]

    def tick(self):
        """Keepalive: ping when idle, give up when the ping is not answered."""
        if self.sock is None:
            return
        now = time.monotonic()
        if self.ping_sent and now - self.ping_sent > KEEPALIVE_S / 2:
            self._fail("no answer to keepalive")
            return
        if not self.ping_sent and now - self.last_sent >= KEEPALIVE_S / 2:
            try:
                self.sock.sendall(PINGREQ)
            except OSError as exc:
                self._fail(str(exc) or "send failed")
                return
            self.ping_sent = self.last_sent = now

    def close(self):
        if self.sock is not None:
            try:
                self.sock.sendall(DISCONNECT)
                self.sock.close()
            except OSError:
                pass
            self.sock = None


def listen(port_file):
    """Listen on loopback; reuse the port of a previous run when possible."""
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    port = 0
    try:
        with open(port_file, encoding="ascii") as fh:
            port = int(fh.read().strip() or 0)
    except (OSError, ValueError):
        pass
    try:
        srv.bind(("127.0.0.1", port))
    except OSError:
        srv.bind(("127.0.0.1", 0))
    srv.listen(128)
    tmp = f"{port_file}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="ascii") as fh:
        fh.write(f"{srv.getsockname()[1]}\n")
    os.replace(tmp, port_file)
    return srv


def serve(srv, broker, stop):
    clients = []  # [socket, buffer] in accept order
    while not stop["now"]:
        broker.try_connect()
        broker.tick()
        rlist = [srv] + [c[0] for c in clients]
        if broker.connected():
            rlist.append(broker.sock)
        timeout = 1.0 if broker.connected() else max(0.05, min(1.0, broker.next_attempt - time.monotonic()))
        try:
            readable, _, _ = select.select(rlist, [], [], timeout)
        except InterruptedError:
            continue
        if srv in readable:
            try:
                conn, _ = srv.accept()
                conn.setblocking(False)
                clients.append([conn, b""])
            except OSError:
                pass
        if broker.connected() and broker.sock in readable:
            broker.on_readable()
        # Serve writers strictly in accept order: a later connection is only
        # read once every earlier one has been closed by its writer.
        while clients:
            conn, buf = clients[0]
            closed = False
            if conn in readable or buf:
                try:
                    chunk = conn.recv(65536)
                    if chunk:
                        buf += chunk
                    else:
                        closed = True
                except BlockingIOError:
                    pass
                except OSError:
                    closed = True
            try:
                while True:
                    msg, buf = parse_frame(buf)
                    if msg is None:
                        break
                    broker.publish(*msg)
            except ValueError as exc:
                log(f"dropping a malformed message ({exc})")
                buf, closed = b"", True
            clients[0][1] = buf
            if not closed:
                break
            conn.close()
            clients.pop(0)
            readable = [r for r in readable if r is not conn]
            if clients:
                readable.append(clients[0][0])


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--host", required=True)
    ap.add_argument("--port", type=int, default=1883)
    ap.add_argument("--port-file", required=True,
                    help="where the loopback port for writers is written")
    args = ap.parse_args(argv)
    # Credentials come from the environment, not argv: argv is visible in ps.
    username = os.environ.get("MQTT_USER") or None
    if username == "null":
        username = None
    password = os.environ.get("MQTT_PASS") or None
    if password == "null":
        password = None

    stop = {"now": False}

    def on_signal(_sig, _frame):
        stop["now"] = True

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    srv = listen(args.port_file)
    broker = Broker(args.host, args.port, username, password,
                    "wmbus_bridge_pub_" + secrets.token_hex(4))
    log(f"listening on 127.0.0.1:{srv.getsockname()[1]}")
    try:
        serve(srv, broker, stop)
    finally:
        broker.flush()
        broker.close()
        srv.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
