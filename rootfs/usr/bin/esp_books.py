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


def _replace(path: str, data: bytes) -> None:
    """`... > path.tmp && mv path.tmp path`: the same temporary name as bash."""
    tmp = path + ".tmp"
    with open(tmp, "wb") as fh:
        fh.write(data)
    os.replace(tmp, path)


class HealthBook:
    """wmbus/+/health -> status_esp_health.json, a map keyed by board.

    13-esp.sh: `jq '. + {($dev): ($p + {_bridge_rx_epoch: $t})}'` over the
    current file ({} when missing or empty). A payload jq cannot take, or a
    current file that is not an object, leaves the file as it is.
    """

    def __init__(self, health_file: str) -> None:
        self.path = health_file

    def __call__(self, topic_b: bytes, payload_b: bytes) -> None:
        if not payload_b:
            return
        topic = bl._s(topic_b)
        dev = topic[len("wmbus/"):] if topic.startswith("wmbus/") else topic
        dev = dev[:-len("/health")] if dev.endswith("/health") else dev
        if not dev or dev == topic:
            return
        ts = int(bl.now())
        try:
            with open(self.path, "rb") as fh:
                cur_text = fh.read().decode("utf-8", "surrogateescape")
        except OSError:
            cur_text = ""
        # `$(cat file)`: command substitution drops the trailing newlines.
        cur_text = cur_text.rstrip("\n")
        if not cur_text:
            cur_text = "{}"
        payload = jq_argjson(bl._s(payload_b))
        if not isinstance(payload, dict):
            return
        values = bl.jq_values(cur_text)
        # jq runs the filter once per input value and fails on the first that
        # is not an object; a parse error after valid values still fails.
        if not values or any(not isinstance(v, dict) for v in values) or _trailing_garbage(cur_text):
            return
        out = []
        for cur in values:
            merged = dict(cur)
            entry = dict(payload)
            entry["_bridge_rx_epoch"] = ts
            merged[dev] = entry
            out.append(jq_pretty(merged) + "\n")
        _replace(self.path, "".join(out).encode("utf-8", "surrogateescape"))


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
