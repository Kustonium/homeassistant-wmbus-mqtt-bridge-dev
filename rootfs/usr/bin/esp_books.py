#!/usr/bin/env python3
"""Bookkeeping of the ESP subscribers that were bash loops in 13-esp.sh.

Each class is one subscriber, ported line for line: it is handed what
mosquitto_sub printed (one line at a time, split as the bash `read` did) and
writes the same file the loop wrote, byte for byte. mqtt_publisher.py runs
them on its broker connection (make_books); tests/test_esp_books.py runs the
bash loop and the class on one corpus and compares the files.
"""

from __future__ import annotations

import os
import re
from typing import Any, Optional

import bridge_ledger as bl

_SPACE = re.compile(r"[ \t\n\v\f\r]")


def jq_pretty(value: Any, indent: int = 0) -> str:
    """`jq .` output of one value (two-space indent), without the final newline."""
    pad, inner = " " * indent, " " * (indent + 2)
    if isinstance(value, dict):
        if not value:
            return "{}"
        items = [inner + bl._jq_string(k) + ": " + jq_pretty(v, indent + 2) for k, v in value.items()]
        return "{\n" + ",\n".join(items) + "\n" + pad + "}"
    if isinstance(value, list):
        if not value:
            return "[]"
        return "[\n" + ",\n".join(inner + jq_pretty(v, indent + 2) for v in value) + "\n" + pad + "]"
    return bl.jq_dumps(value)


def jq_argjson(text: str) -> Optional[Any]:
    """The value of `--argjson p "$text"`, or None where jq refuses it: the
    text must be exactly one JSON value (whitespace around it allowed)."""
    i, n = 0, len(text)
    while i < n and text[i] in bl._JQ_WS:
        i += 1
    try:
        value, j = bl._DECODER.raw_decode(text, i)
    except ValueError:
        return None
    while j < n and text[j] in bl._JQ_WS:
        j += 1
    return value if j == n else None


class _JqError(Exception):
    """The jq program would stop with an error: bash then writes nothing."""


def jq_add(a: Any, b: dict) -> dict:
    """jq's `a + b` for an object b: null + b is b; anything but an object fails."""
    if a is None:
        return dict(b)
    if not isinstance(a, dict):
        raise _JqError(f"cannot add an object to {type(a).__name__}")
    out = dict(a)
    out.update(b)
    return out


def jq_inputs(text: str) -> list:
    """The values jq reads from text; _JqError when it would stop at a parse error."""
    values = bl.jq_values(text)
    if _trailing_garbage(text):
        raise _JqError("parse error")
    return values


def _read_current(path: str) -> str:
    """`$(cat file)`, {} when missing or empty (command substitution drops the
    trailing newlines)."""
    try:
        with open(path, "rb") as fh:
            text = fh.read().decode("utf-8", "surrogateescape")
    except OSError:
        text = ""
    return text.rstrip("\n") or "{}"


def _write_outputs(path: str, outputs: list) -> None:
    _replace(path, "".join(jq_pretty(v) + "\n" for v in outputs).encode("utf-8", "surrogateescape"))


def _replace(path: str, data: bytes) -> None:
    """`... > path.tmp && mv path.tmp path`: the same temporary name as bash."""
    tmp = path + ".tmp"
    with open(tmp, "wb") as fh:
        fh.write(data)
    os.replace(tmp, path)


class DeviceMapBook:
    """wmbus/<board><suffix> -> a JSON map keyed by board (13-esp.sh's health,
    meters and meter_snapshot loops, which differ only in suffix and file).

    `jq '. + {($dev): ($p + {_bridge_rx_epoch: $t})}'` over the current file
    ({} when missing or empty). A payload jq cannot take, or a current file
    that is not an object, leaves the file as it is.
    """

    suffix = ""

    def __init__(self, path: str) -> None:
        self.path = path

    def __call__(self, topic_b: bytes, payload_b: bytes) -> None:
        if not payload_b:
            return
        topic = bl._s(topic_b)
        dev = topic[len("wmbus/"):] if topic.startswith("wmbus/") else topic
        dev = dev[:-len(self.suffix)] if dev.endswith(self.suffix) else dev
        if not dev or dev == topic:
            return
        ts = int(bl.now())
        text = bl._s(payload_b)
        payload = jq_argjson(text)
        if payload is None and text.strip(bl._JQ_WS) != "null":
            return  # --argjson refused it: jq does not run
        try:
            entry = jq_add(payload, {"_bridge_rx_epoch": ts})
            # The filter runs once per value of the current file.
            outputs = [jq_add(cur, {dev: entry}) for cur in jq_inputs(_read_current(self.path))]
        except _JqError:
            return
        _write_outputs(self.path, outputs)


class SummaryBook:
    """wmbus/+/diag/summary -> status_esp_diag.json (the last summary).

    13-esp.sh pipes the payload line into `jq '. + {_bridge_rx_epoch: $t,
    _topic: $topic}'`: every JSON value of the line is one input, and a parse
    or type error anywhere keeps the file as it is.
    """

    def __init__(self, path: str) -> None:
        self.path = path

    def __call__(self, topic_b: bytes, payload_b: bytes) -> None:
        if not payload_b:
            return
        add = {"_bridge_rx_epoch": int(bl.now()), "_topic": bl._s(topic_b)}
        try:
            outputs = [jq_add(v, add) for v in jq_inputs(bl._s(payload_b) + "\n")]
        except _JqError:
            return
        _write_outputs(self.path, outputs)


class MeterWindowBook:
    """wmbus/<board>/diag/meter/<id>/<mode>/window/<trigger> ->
    status_esp_meter_window.json, a map board -> meter id -> last window.

    `($p.id // "") as $id | if $id == "" then .
     else .[$dev] = ((.[$dev] // {}) + {($id): ($p + {_bridge_rx_epoch: $t})}) end`
    """

    def __init__(self, path: str) -> None:
        self.path = path

    def __call__(self, topic_b: bytes, payload_b: bytes) -> None:
        if not payload_b:
            return
        topic = bl._s(topic_b)
        dev = topic[len("wmbus/"):] if topic.startswith("wmbus/") else topic
        cut = dev.find("/diag/meter/")
        dev = dev[:cut] if cut >= 0 else dev
        if not dev or dev == topic:
            return
        ts = int(bl.now())
        text = bl._s(payload_b)
        p = jq_argjson(text)
        if p is None and text.strip(bl._JQ_WS) != "null":
            return
        try:
            if p is None:
                mid = None
            elif isinstance(p, dict):
                mid = p.get("id")
            else:
                raise _JqError("cannot index")
            mid = "" if mid is None or mid is False else mid
            outputs = []
            for cur in jq_inputs(_read_current(self.path)):
                if mid == "":
                    outputs.append(cur)
                    continue
                if not isinstance(mid, str):
                    raise _JqError("object keys must be strings")
                if cur is not None and not isinstance(cur, dict):
                    raise _JqError("cannot index with a string")
                board = (cur or {}).get(dev)
                board = {} if board is None or board is False else board
                merged = dict(cur or {})
                merged[dev] = jq_add(board, {mid: jq_add(p, {"_bridge_rx_epoch": ts})})
                outputs.append(merged)
        except _JqError:
            return
        _write_outputs(self.path, outputs)


class HealthBook(DeviceMapBook):
    """wmbus/+/health -> status_esp_health.json (always-on radio pulse)."""
    suffix = "/health"


class MetersBook(DeviceMapBook):
    """wmbus/+/meters -> status_esp_meters.json (target/highlight per board)."""
    suffix = "/meters"


class MeterSnapshotBook(DeviceMapBook):
    """wmbus/+/diag/meter_snapshot -> status_esp_meter_snapshot.json."""
    suffix = "/diag/meter_snapshot"


def _trailing_garbage(text: str) -> bool:
    """True when text holds anything after its JSON values that jq would fail on."""
    i, n = 0, len(text)
    while True:
        while i < n and text[i] in bl._JQ_WS:
            i += 1
        if i >= n:
            return False
        try:
            _, i = bl._DECODER.raw_decode(text, i)
        except ValueError:
            return True


class HaPresenceBook:
    """<discovery_prefix>/status -> status_ha_presence.txt ("state<TAB>epoch").

    The loop read `mosquitto_sub -F '%p'`, so it is handed payload lines; all
    whitespace is dropped and case folded, and only online/offline count.
    """

    def __init__(self, presence_file: str) -> None:
        self.path = presence_file

    def __call__(self, _topic_b: bytes, line_b: bytes) -> None:
        if not line_b:
            return
        state = _SPACE.sub("", bl._s(line_b)).lower()
        if state not in ("online", "offline"):
            return
        _replace(self.path, f"{state}\t{int(bl.now())}\n".encode())
