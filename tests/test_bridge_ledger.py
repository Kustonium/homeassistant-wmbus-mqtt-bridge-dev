"""Unit tests for the shared primitives of bridge_ledger.py.

Each helper stands in for a bash helper in bridge-lib/03-tsv.sh, so where the
outcome can be compared the bash helper is run on the same input and the two
files must be byte-identical.
"""
from __future__ import annotations

import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "rootfs" / "usr" / "bin"))

import bridge_ledger as bl  # noqa: E402

TSV_LIB = ROOT / "rootfs" / "usr" / "bin" / "bridge-lib" / "03-tsv.sh"


def bash(script: str, *args: str) -> None:
    subprocess.run(["bash", "-c", f'source "{TSV_LIB}"; {script}', "bash", *args], check=True)


class TsvTest(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.d = Path(self.dir.name)

    def pair(self, content: bytes | None):
        """Two copies of the same starting file: one for bash, one for Python."""
        a, b = self.d / "bash.tsv", self.d / "py.tsv"
        for p in (a, b):
            if content is not None:
                p.write_bytes(content)
        return a, b

    def test_upsert_matches_bash(self):
        cases = [
            (None, "AAAA0001", "AAAA0001\tnew"),  # missing file
            (b"", "AAAA0001", "AAAA0001\tnew"),  # empty file
            (b"AAAA0001\told\nBBBB0002\tkeep\n", "AAAA0001", "AAAA0001\tnew"),  # replace
            (b"BBBB0002\tkeep\n", "AAAA0001", "AAAA0001\tnew"),  # insert
            (b"AAAA0001\tx\nAAAA0001\ty\nC\tz\n", "AAAA0001", "AAAA0001\tnew"),  # duplicates
            (b"BBBB0002\tno newline", "AAAA0001", "AAAA0001\tnew"),  # last line unterminated
            (b"\nBBBB0002\tkeep\n\n", "AAAA0001", "AAAA0001\tnew"),  # empty lines kept
            (b"AAAA0001x\tlonger\n", "AAAA0001", "AAAA0001\tnew"),  # prefix is not a match
            (b"aaaa0001\tlower\n", "AAAA0001", "AAAA0001\tnew"),  # case-sensitive, as awk
        ]
        for content, key, row in cases:
            with self.subTest(content=content):
                a, b = self.pair(content)
                bash('_tsv_upsert "$1" "$2" "$3"', str(a), key, row)
                bl.tsv_upsert(str(b), key, row)
                self.assertEqual(a.read_bytes(), b.read_bytes())

    def test_remove_matches_bash(self):
        for content in (b"AAAA0001\tx\nBBBB0002\ty\n", b"BBBB0002\ty\n", b""):
            with self.subTest(content=content):
                a, b = self.pair(content)
                bash('_tsv_remove_id "$1" "$2"', str(a), "AAAA0001")
                bl.tsv_remove(str(b), "AAAA0001")
                self.assertEqual(a.read_bytes(), b.read_bytes())
        missing = self.d / "missing.tsv"
        bl.tsv_remove(str(missing), "AAAA0001")
        self.assertFalse(missing.exists())

    def test_numeric_looking_ids_stay_distinct(self):
        # BusyBox awk would compare these numerically (both 1000) and let one
        # replace the other; they are different meters.
        p = self.d / "ids.tsv"
        p.write_bytes(b"0001E003\tfirst\n")
        bl.tsv_upsert(str(p), "00001000", "00001000\tsecond")
        self.assertEqual(p.read_bytes(), b"0001E003\tfirst\n00001000\tsecond\n")

    def test_replaced_file_has_mktemp_mode_and_no_leftovers(self):
        p = self.d / "mode.tsv"
        bl.tsv_upsert(str(p), "A", "A\t1")
        self.assertEqual(stat.S_IMODE(p.stat().st_mode), 0o600)
        self.assertEqual(sorted(x.name for x in self.d.iterdir()), ["mode.tsv", "mode.tsv.lock"])

    def test_append_and_trim_match_bash(self):
        a, b = self.pair(b"")
        for n in range(1, 8):
            # What the former bash _append_esp_rx_history wrote (jq -c, one line).
            with open(a, "ab") as fh:
                fh.write(f'{{"time":{n},"source":"lilygo","meter_id":"52632878","topic":"wmbus/lilygo/telegram"}}\n'.encode())
            bl.append_locked(str(b), f'{{"time":{n},"source":"lilygo","meter_id":"52632878","topic":"wmbus/lilygo/telegram"}}')
        self.assertEqual(a.read_bytes(), b.read_bytes())
        for max_lines, keep in ((7, 3), (6, 3)):  # at the limit nothing happens; above it, trim
            with self.subTest(max_lines=max_lines):
                bash('_trim_esp_rx_history "$1" "$2" "$3"', str(a), str(max_lines), str(keep))
                bl.trim_locked(str(b), max_lines, keep)
                self.assertEqual(a.read_bytes(), b.read_bytes())
        self.assertEqual(len(b.read_bytes().splitlines()), 3)


class ReceptionHistoryTest(unittest.TestCase):
    """The ESP reception files the WebUI reads, as tests/test_esp_reception_history.sh
    checked them on the former bash helpers (same cases, same expectations)."""

    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.d = Path(self.dir.name)

    def rows(self, name: str):
        return [ln.split("\t") for ln in (self.d / name).read_text().splitlines()]

    def test_reception_first_last_count_per_board(self):
        f = str(self.d / "reception.tsv")
        bl.upsert_meter_reception(f, "00089907", "lr1121", 100, "wmbus/lr1121/telegram")
        bl.upsert_meter_reception(f, "00089907", "heltec", 101, "wmbus/heltec/telegram")
        bl.upsert_meter_reception(f, "00089907", "lr1121", 105, "wmbus/lr1121/telegram")
        rows = {r[1]: r[2:5] for r in self.rows("reception.tsv") if r[0] == "00089907"}
        self.assertEqual(rows, {"lr1121": ["100", "105", "2"], "heltec": ["101", "101", "1"]})

    def test_history_retention(self):
        f = str(self.d / "history.jsonl")
        for n in range(1, 6):
            bl.append_locked(f, bl.jq_dumps({"time": n, "source": "lr1121", "meter_id": "00089907",
                                             "topic": "wmbus/lr1121/telegram"}))
        bl.trim_locked(f, 4, 3)
        lines = [json.loads(x) for x in (self.d / "history.jsonl").read_text().splitlines()]
        self.assertEqual([x["time"] for x in lines], [3, 4, 5])
        self.assertTrue(all(x["meter_id"] == "00089907" for x in lines))

    def test_rf_history_and_normalisation(self):
        files = {n: str(self.d / n) for n in ("reception", "mode", "history", "sequence", "boots", "clock")}
        book = bl.RxBook(files["reception"], files["mode"], files["history"], files["sequence"],
                         files["boots"], files["clock"])
        payload = ('{"schema":1,"boot_id":"A84F12C7","seq":7,"rx_task_wakeup_us":123456,'
                   '"meter_id":"00089907","mode":"T1","rssi_dbm":-54,"frame_crc32":"7F56A83C",'
                   '"frame_length":123}')
        norm = bl.normalize_rx(bl.jq_values(payload)[0])
        self.assertEqual((norm["meter_id"], norm["boot_id"], norm["frame_crc32"]),
                         ("00089907", "A84F12C7", "7F56A83C"))
        self.assertIsNone(bl.normalize_rx(bl.jq_values('{"schema":1,"meter_id":"NOT_AN_ID"}')[0]))
        old = bl.now
        bl.now = lambda: 200.0
        self.addCleanup(setattr, bl, "now", old)
        book(b"wmbus/lr1121/rx", payload.encode())
        rows = [json.loads(x) for x in (self.d / "history").read_text().splitlines()]
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]["source"], rows[0]["bridge_rx_time"], rows[0]["seq"]), ("lr1121", 200, 7))

    def test_sequence_gaps_reorder_and_boot_reset(self):
        f = str(self.d / "sequence.tsv")
        for seq, ts in (("7", 200), ("10", 201), ("10", 202)):
            bl.upsert_rx_sequence(f, "lr1121", "A84F12C7", seq, ts)
        self.assertEqual(self.rows("sequence.tsv")[0][2:5], ["10", "2", "1"])  # gap + duplicate
        bl.upsert_rx_sequence(f, "lr1121", "DEADBEEF", "1", 203)
        self.assertEqual(self.rows("sequence.tsv")[0][1:5], ["DEADBEEF", "1", "0", "0"])
        # A late or redelivered frame must not invent a gap (seen on hardware
        # 2026-08-21: three boards reported missing=1 while the broker redelivered).
        g = str(self.d / "reorder.tsv")
        for n in ("1", "2", "3", "5", "4", "6", "7"):
            bl.upsert_rx_sequence(g, "lilygo", "AAAA", n, 1000)
        self.assertEqual(self.rows("reorder.tsv")[0][2:5], ["7", "1", "1"])

    def test_one_row_per_boot_and_scientific_looking_ids(self):
        f = str(self.d / "boots.tsv")
        for boot, ts in (("AAAA", 1000), ("AAAA", 1100), ("BBBB", 2000)):
            bl.upsert_rx_boot(f, "lilygo", boot, ts)
        rows = self.rows("boots.tsv")
        self.assertEqual(len(rows), 2)
        self.assertEqual(next(r for r in rows if r[1] == "AAAA")[2:5], ["1000", "1100", "2"])
        # BusyBox awk read 651E6871 / 999E9999 as numbers; XIAO produced 651E6871 in the field.
        g = str(self.d / "sci.tsv")
        bl.upsert_rx_boot(g, "xiaoseed", "999E9999", 1000)
        for n in range(1, 6):
            bl.upsert_rx_boot(g, "xiaoseed", "651E6871", 1000 + n)
        rows = self.rows("sci.tsv")
        self.assertEqual(len(rows), 2)
        self.assertEqual(next(r for r in rows if r[1] == "651E6871")[2:5], ["1001", "1005", "5"])
        h = str(self.d / "sciseq.tsv")
        bl.upsert_rx_sequence(h, "xiaoseed", "999E9999", "40", 1000)
        bl.upsert_rx_sequence(h, "xiaoseed", "651E6871", "1", 1001)
        self.assertEqual(self.rows("sciseq.tsv")[0][1:5], ["651E6871", "1", "0", "0"])

    def test_band_counts_per_meter(self):
        f = str(self.d / "modes.tsv")
        for mode, ts in (("T1", 300), ("C1", 301), ("T1", 302), ("S1", 303), ("XX", 304)):
            bl.upsert_meter_mode(f, "90830781", mode, ts)
        rows = {r[1]: r[2:4] for r in self.rows("modes.tsv")}
        self.assertEqual(rows, {"T1": ["2", "302"], "C1": ["1", "301"], "S1": ["1", "303"]})


class SplitMessageTest(unittest.TestCase):
    LINES = [
        b"wmbus/lilygo/telegram\tABCDEF\n",
        b"wmbus/lilygo/telegram\t\tABCDEF\n",  # run of tabs
        b"\twmbus/lilygo/telegram\tABCDEF\t\n",  # leading/trailing tabs
        b"wmbus/lilygo/rx\t{\"a\": 1,\t\"b\": \"x y\"}\n",  # tab inside payload
        b"wmbus/lilygo/telegram\t  spaced  \n",  # spaces are kept
        b"wmbus/lilygo/telegram\n",  # no payload
        b"\n",
    ]

    def test_matches_bash_read(self):
        script = r"""while IFS=$'\t' read -r t p; do printf '%s\x1f%s\x1e' "$t" "$p"; done"""
        out = subprocess.run(["bash", "-c", script], input=b"".join(self.LINES),
                             capture_output=True, check=True).stdout
        expected = [tuple(rec.split(b"\x1f")) for rec in out.split(b"\x1e")[:-1]]
        self.assertEqual([bl.split_message(ln) for ln in self.LINES], expected)


class RunLoopTest(unittest.TestCase):
    def test_failing_message_is_skipped_not_fatal(self):
        seen = []

        def handler(topic: bytes, payload: bytes) -> None:
            if payload == b"boom":
                raise ValueError("bad payload")
            seen.append((topic, payload))

        err = io.StringIO()
        bl.run(handler, io.BytesIO(b"a\t1\nb\tboom\nc\t3\n"), err)
        self.assertEqual(seen, [(b"a", b"1"), (b"c", b"3")])
        self.assertIn("skipped", err.getvalue())

    def test_unknown_mode_is_a_usage_error(self):
        self.assertEqual(bl.main(["no-such-mode"]), 2)


class RssiBookTest(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.d = Path(self.dir.name)
        self.meters = self.d / "meters"
        self.meters.mkdir()
        (self.meters / "meter-0001").write_text("name=water\nid=52632878\ndriver=auto\n")
        self.rssi = self.d / "status_rssi.tsv"
        self.clock = [1_000_000.0]
        self.addCleanup(setattr, bl, "now", bl.now)
        bl.now = lambda: self.clock[0]
        self.book = bl.RssiBook(str(self.meters), str(self.rssi))

    def rows(self):
        return self.rssi.read_text().splitlines() if self.rssi.exists() else []

    def test_configured_meter_is_stored_per_board(self):
        self.book(b"wmbus/lilygo/rssi/52632878", b"-70")
        self.book(b"wmbus/heltec/rssi/52632878", b"-81")
        self.book(b"wmbus/lilygo/rssi/52632878", b"-66")
        self.assertEqual(self.rows(), ["52632878\t-81\theltec\t1000000", "52632878\t-66\tlilygo\t1000000"])

    def test_meter_added_later_is_picked_up_after_30_s(self):
        self.book(b"wmbus/lilygo/rssi/52632878", b"-70")  # loads the configured ids
        (self.meters / "meter-0002").write_text("id=abcdef12\n")
        self.clock[0] += 29
        self.book(b"wmbus/lilygo/rssi/ABCDEF12", b"-60")
        self.assertEqual(len(self.rows()), 1)
        self.clock[0] += 1
        self.book(b"wmbus/lilygo/rssi/abcdef12", b"-60")
        self.assertIn("ABCDEF12\t-60\tlilygo\t1000030", self.rows())

    def test_values_read_like_bash_arithmetic(self):
        self.assertEqual(bl.bash_int("-070"), -56)  # leading 0 = octal
        self.assertIsNone(bl.bash_int("-089"))  # invalid octal: bash errors, value rejected
        self.assertEqual(bl.bash_int("-125"), -125)
        for val in (b"-127", b"0", b"1", b"-0", b"abc", b"-70 ", b"-089", b""):
            self.book(b"wmbus/lilygo/rssi/52632878", val)
        self.assertEqual(self.rows(), [])
        self.book(b"wmbus/lilygo/rssi/52632878", b"-070")  # stored as received
        self.assertEqual(self.rows(), ["52632878\t-070\tlilygo\t1000000"])


class RxPrimitivesTest(unittest.TestCase):
    """Values checked against jq 1.7.1 and musl in the add-on image 1.5.70-dev.337."""

    def test_numbers_and_strings_as_jq_writes_them(self):
        cases = {"1": "1", "1.0": "1.0", "1.50": "1.50", "1e3": "1E+3", "1E3": "1E+3",
                 "1.0e2": "1.0E+2", "100e-2": "1.00", "0.1": "0.1", "0.000001": "0.000001",
                 "0.0000001": "1E-7", "-0": "-0", "-0.0": "-0.0", "1e400": "1E+400",
                 "12345678901234567890": "12345678901234567890"}
        for literal, expected in cases.items():
            with self.subTest(literal=literal):
                self.assertEqual(bl.jq_dumps(bl.jq_values(f'{{"x":{literal}}}')[0]), f'{{"x":{expected}}}')
        self.assertEqual(bl.jq_dumps(bl.jq_values('{"s":"a\\u0001b\\u007fc\\u2028d\\/e\\u00e9f\\tg"}')[0]),
                         '{"s":"a\\u0001b\\u007fc\u2028d/e\u00e9f\\tg"}')
        self.assertEqual(bl.jq_dumps(bl.jq_values('{"a":1,"b":2,"a":3}')[0]), '{"a":3,"b":2}')
        self.assertEqual(bl.jq_values('{"s":"raw\ttab"}'), [])  # jq rejects raw control characters
        self.assertEqual(len(bl.jq_values('{"a":1}{"a":2} xx {"a":3}')), 2)  # up to the parse error

    def test_received_at_as_musl_strptime_and_timegm_read_it(self):
        cases = {
            "2026-10-02T10:00:00.000Z": "1790935200",
            "2026-10-02T10:00:00.123Z\n": "1790935200",  # test() accepts a final newline
            "2026-02-30T10:00:00.000Z": "1772445600",  # rolls over into March
            "2026-10-02T23:59:60.000Z": "1790985600",  # leap second accepted
            "2026-13-01T10:00:00.000Z": "",
            "2026-00-10T10:00:00.000Z": "",
            "2026-10-00T10:00:00.000Z": "",
            "2026-10-32T00:00:00.000Z": "",
            "2026-10-02T24:00:00.000Z": "",
            "2026-10-02T23:60:00.000Z": "",
            "1969-12-31T23:59:59.000Z": "",  # timegm's -1 is its error value
            "0000-01-01T00:00:00.000Z": "-62167219200",
        }
        for text, expected in cases.items():
            with self.subTest(text=text):
                self.assertEqual(bl.received_epoch(text), expected)
        self.assertEqual(bl.received_epoch(None), "")

    def test_bash_read_takes_the_first_line_and_leaves_the_rest_to_the_last_field(self):
        self.assertEqual(bl.bash_read_fields("a\x1fb\x1fc", 2, "\x1f"), ["a", "b\x1fc"])
        self.assertEqual(bl.bash_read_fields("a\x1fB\nX\x1fc", 3, "\x1f"), ["a", "B", ""])
        self.assertEqual(bl.bash_read_fields("a\x1fb\x1f", 3, "\x1f"), ["a", "b", ""])


class RxBookTest(unittest.TestCase):
    BASE = ('"schema":1,"rx_task_wakeup_us":1,"mode":"T1","frame_crc32":"7F56A83C",'
            '"frame_length":10,"meter_id":"52632878","boot_id":"A84F12C7"')

    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.d = Path(self.dir.name)
        self.clock = [1_790_935_210.0]
        self.addCleanup(setattr, bl, "now", bl.now)
        bl.now = lambda: self.clock[0]
        self.files = {n: str(self.d / n) for n in ("reception", "mode", "history", "sequence", "boots", "clock")}
        self.book = bl.RxBook(*(self.files[n] for n in ("reception", "mode", "history", "sequence", "boots", "clock")))

    def send(self, board: str, extra: str) -> None:
        self.book(f"wmbus/{board}/rx".encode(), ("{" + self.BASE + "," + extra + "}").encode())
        self.book.deferred.flush()  # rows per message; DeferredTest covers the batching

    def read(self, name: str):
        return Path(self.files[name]).read_text().splitlines()

    def test_clock_skew_is_kept_from_the_last_stamped_frame(self):
        self.send("lilygo", '"seq":1,"received_at":"2026-10-02T10:00:00.500Z"')  # stamped 1790935200
        self.clock[0] += 5
        self.send("lilygo", '"seq":2')  # unstamped
        self.assertEqual(self.read("clock"), ["lilygo\t1790935200\t1790935215\t10\t1\t1"])

    def test_numeric_looking_keys_stay_distinct(self):
        self.send("1000", '"seq":1')
        self.send("1E3", '"seq":1')
        self.assertEqual([r.split("\t")[1] for r in self.read("reception")], ["1000", "1E3"])
        self.assertEqual([r.split("\t")[0] for r in self.read("sequence")], ["1000", "1E3"])

    def test_history_is_trimmed_every_1000_messages(self):
        self.book.TRIM_EVERY = 3
        Path(self.files["history"]).write_text("old\n" * 100001)
        for n in range(1, 4):
            self.send("lilygo", f'"seq":{n}')
        self.assertEqual(len(self.read("history")), 90000)


class TrackerBookTest(unittest.TestCase):
    QWATER = "".join((ROOT / "tests/fixtures/qwaterv2/52632878.hex").read_text().split())

    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.d = Path(self.dir.name)
        self.clock = [1_790_935_200.0]
        self.addCleanup(setattr, bl, "now", bl.now)
        bl.now = lambda: self.clock[0]
        self.files = {n: self.d / n for n in ("devices", "meter_device", "reception", "history")}
        for name in ("devices", "meter_device"):
            self.files[name].write_text("")  # created by bridge.sh at start
        self.book = bl.TrackerBook(1, *(str(self.files[n]) for n in ("devices", "meter_device", "reception", "history")))

    def send(self, board: str) -> None:
        self.book(f"wmbus/{board}/telegram".encode(), self.QWATER.encode())
        self.book.deferred.flush()  # rows per message; DeferredTest covers the batching
        self.clock[0] += 10

    def test_meter_board_row_is_written_only_when_the_board_changes(self):
        self.send("lilygo")
        self.send("lilygo")
        self.assertEqual(self.files["meter_device"].read_text(), "52632878\tlilygo\t1790935200\n")
        self.send("heltec")
        self.assertEqual(self.files["meter_device"].read_text(), "52632878\theltec\t1790935220\n")
        self.assertEqual(self.files["devices"].read_text().splitlines(),
                         ["lilygo\t1790935210\twmbus/lilygo/telegram\t2",
                          "heltec\t1790935220\twmbus/heltec/telegram\t1"])

    def test_meter_id_matches_the_bash_parser_on_every_fixture(self):
        lib = ROOT / "rootfs" / "usr" / "bin" / "bridge-lib" / "05-raw.sh"
        for path in sorted((ROOT / "tests" / "fixtures").glob("*/*.hex")):
            raw = "".join(path.read_text().split()).upper()
            for frame in (raw, raw[:-2], raw[:8] + "0001E003" + raw[16:]):
                with self.subTest(frame=path.name):
                    expected = subprocess.run(
                        ["bash", "-c", f'source "{lib}"; meter_id_from_raw_hex "$1"', "bash", frame],
                        capture_output=True, text=True, check=True).stdout.strip()
                    self.assertEqual(bl.meter_id_from_raw_hex(frame), expected)

    def test_missing_files_are_not_created(self):
        self.files["devices"].unlink()
        self.send("lilygo")
        self.assertFalse(self.files["devices"].exists())  # awk on a missing file writes nothing


class RawBookRequestTest(unittest.TestCase):
    """Work handed to bash only when the bash code would get past its own checks:
    an extra request is invisible in the files, but costs a bash call."""

    IZAR = "".join((ROOT / "tests/fixtures/izar/2156B4C2.hex").read_text().split())
    QWATER = "".join((ROOT / "tests/fixtures/qwaterv2/52632878.hex").read_text().split())

    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        d = Path(self.dir.name)
        (d / "preview").mkdir()
        (d / "last").mkdir()
        self.candidates = d / "candidates.tsv"
        self.args = bl._parser().parse_args([
            "raw", *(f"--{n}-file={d / n}" for n in (
                "raw-count", "last-raw", "recent-raw", "broker-error", "events",
                "rate", "rate-history", "status-json", "discovery-flag")),
            f"--candidates-file={self.candidates}",
            *(f"--{n}-file={d / n}" for n in ("seen", "candidate-raw", "candidate-analysis")),
            f"--meter-dir={d / 'meters'}", f"--preview-state-file={d / 'states'}",
            f"--preview-meter-dir={d / 'preview'}", f"--preview-last-dir={d / 'last'}"])
        (d / "meters").mkdir()
        self.d = d
        self.preview, self.last = d / "preview", d / "last"
        self.out = io.StringIO()
        self.book = bl.RawBook(self.args, self.out)

    def requests(self, raw: str):
        self.out.seek(0)
        self.out.truncate()
        self.book.candidate(raw)
        self.book.preview(raw)
        return self.out.getvalue().splitlines()

    def frame(self, meter_le: str) -> str:
        return self.IZAR[:8] + meter_le + self.IZAR[16:]

    def test_sap_registration_requested_only_when_bash_would_register(self):
        rows = {"11223344": "\tauto\tWater meter (0x07)",  # unknown driver: register
                "22334455": "\tizar\tWater meter (0x07)",  # known driver
                "33445566": "\tauto\tWater meter (0x07) encrypted",
                "44556677": "\t\tWater meter (0x07)"}  # read shifts the type into the driver
        self.candidates.write_text("".join(k + v + "\n" for k, v in rows.items()))
        def le(meter): return meter[6:8] + meter[4:6] + meter[2:4] + meter[0:2]
        self.assertEqual(self.requests(self.frame(le("11223344"))), [f"sap\t{self.frame(le('11223344'))}"])
        for meter in ("22334455", "33445566", "44556677"):
            with self.subTest(meter=meter):
                self.assertEqual(self.requests(self.frame(le(meter))), [])
        self.assertEqual(self.requests(self.frame(le("55667788"))), [f"sap\t{self.frame(le('55667788'))}"])  # no row
        self.assertEqual(self.requests(self.QWATER), [])  # not SAP

    def test_preview_requested_only_past_the_throttle(self):
        (self.preview / "meter-preview-52632878").write_text("id=52632878\n")
        self.assertEqual(self.requests(self.QWATER), [f"preview\t{self.QWATER}\t52632878"])
        (self.last / "52632878").write_text(f"{int(bl.now())}\n")
        self.assertEqual(self.requests(self.QWATER), [])  # decoded less than 20 s ago
        (self.preview / "meter-preview-52632878").unlink()
        (self.last / "52632878").unlink()
        (self.preview / "meter-preview-abcdef12").write_text("id=abcdef12\n")
        abcd = self.QWATER[:8] + "12EFCDAB" + self.QWATER[16:]
        self.assertEqual(self.requests(abcd), [])  # bash looks for meter-preview-ABCDEF12

    def test_decoded_value_is_decoded_again_only_after_300_s(self):
        (self.preview / "meter-preview-52632878").write_text("id=52632878\n")
        request = [f"preview\t{self.QWATER}\t52632878"]
        for state, ago, expected in (("decoded_value", 100, []), ("decoded_value", 299, []),
                                     ("decoded_value", 300, request), ("pending", 21, request),
                                     ("no_decode_result", 21, request), ("pending", 19, [])):
            with self.subTest(state=state, ago=ago):
                (self.d / "states").write_text(f"52632878\t{state}\tT\t\n")
                (self.last / "52632878").write_text(f"{int(bl.now()) - ago}\n")
                self.assertEqual(self.requests(self.QWATER), expected)

    def test_sap_auto_candidate_registered_as_is_is_refreshed_without_bash(self):
        sap01 = self.frame("44332211")  # 11223344, device type 01: bash registers it as auto
        label = "Unknown meter type (0x01)"
        self.candidates.write_text(f"11223344\tauto\t{label}\tT\t1\t0\t1\t1\t(SAP) Diehl Metering\n"
                                   "99999999\tauto\tGas meter (0x03)\tT\t1\t0\t1\t1\t\n")
        (self.preview / "meter-preview-11223344").write_text("name=preview_11223344\nid=11223344\n")
        (self.last / "11223344").write_text(f"{int(bl.now()) + 3600}\n")  # no one-shot in this test
        before = self.candidates.read_text()
        self.assertEqual(self.requests(sap01), [])
        # The candidate row waits for the deferred write; the reception row does not.
        self.assertEqual(self.candidates.read_text(), before)
        self.book.deferred.flush()
        rows = self.candidates.read_text().splitlines()
        self.assertEqual(rows[0].split("\t")[0], "99999999")  # the refreshed row moves to the end
        f = rows[1].split("\t")
        self.assertEqual((f[0], f[1], f[2], f[4], f[8]),
                         ("11223344", "auto", label, "1", "(SAP) Diehl Metering"))
        self.assertTrue((self.d / "seen").read_text().startswith("11223344\tcandidate\t"))
        self.assertTrue((self.d / "candidate-analysis").read_text().startswith("11223344\tunknown\t"))
        # Anything bash would change still goes to bash.
        cases = {
            "type differs": lambda: self.candidates.write_text(f"11223344\tauto\tWater meter (0x07)\n"),
            "no preview config": lambda: (self.preview / "meter-preview-11223344").unlink(),
            "preview config differs": lambda: (self.preview / "meter-preview-11223344").write_text("id=11223344\n"),
            "official meter, preview to remove": lambda: (self.d / "meters" / "meter-x").write_text("id=11223344\n"),
        }
        for name, change in cases.items():
            with self.subTest(name):
                self.candidates.write_text(f"11223344\tauto\t{label}\n")
                (self.preview / "meter-preview-11223344").write_text("name=preview_11223344\nid=11223344\n")
                for meter in (self.d / "meters").iterdir():
                    meter.unlink()
                change()
                self.assertEqual(self.requests(sap01), [f"sap\t{sap01}"])
        with self.subTest("a one-shot reclassifies the row while the refresh runs"):
            self.candidates.write_text(f"11223344\tauto\t{label}\n")
            (self.preview / "meter-preview-11223344").write_text("name=preview_11223344\nid=11223344\n")
            for meter in (self.d / "meters").iterdir():
                meter.unlink()
            real = bl.record_seen

            def one_shot_writes(*args):  # status_candidate_seen_from_json, between read and write
                real(*args)
                self.candidates.write_text("11223344\tizarv2\twater\n")
            bl.record_seen = one_shot_writes
            try:
                self.assertEqual(self.requests(sap01), [f"sap\t{sap01}"])  # bash decides again
            finally:
                bl.record_seen = real
            self.assertEqual(self.candidates.read_text(), "11223344\tizarv2\twater\n")
            (self.d / "meters" / "meter-x").write_text("id=11223344\n")
        with self.subTest("official meter without a preview config"):
            self.candidates.write_text(f"11223344\tauto\t{label}\n")
            (self.preview / "meter-preview-11223344").unlink()
            self.assertEqual(self.requests(sap01), [])


class CandidateRefreshTest(unittest.TestCase):
    """candidate_seen_refresh: the reception bookkeeping of status_candidate_seen."""

    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        d = Path(self.dir.name)
        self.d = d
        self.files = bl.CandidateFiles(str(d / "candidates"), str(d / "seen"), str(d / "ring"),
                                       str(d / "craw"), str(d / "analysis"), str(d / "preview"),
                                       str(d / "meters"))
        self.clock = [1790935200.0]
        old = bl.now
        bl.now = lambda: self.clock[0]
        self.addCleanup(setattr, bl, "now", old)

    def test_reception_within_two_seconds_is_booked_once(self):
        (self.d / "seen").write_text("11223344\tmeter\t1790935199\n")  # another kind: no threshold
        for step in (0, 1, 1, 5):
            self.clock[0] += step
            bl.record_seen(self.files.seen, "11223344", "candidate")
        self.assertEqual((self.d / "seen").read_text().splitlines(),
                         ["11223344\tmeter\t1790935199", "11223344\tcandidate\t1790935200",
                          "11223344\tcandidate\t1790935202", "11223344\tcandidate\t1790935207"])

    def _deferred_site(self, name: str):
        """A directory with three registered candidates, two of them in the RAW ring."""
        d = self.d / name
        d.mkdir()
        (d / "candidates").write_text("".join(
            f"{m}\tdrv\tWater meter (0x07)\tT\t1\t0\t1\t1\t{mf}\n"
            for m, mf in (("11223344", "(BMT) Bmeters"), ("22334455", ""), ("33445566", "QDS"))))
        (d / "ring").write_text("".join(
            f"2026-10-02T10:00:0{i}+00:00\t26\t2E44B4094{le}0107A\n"
            for i, le in enumerate(("44332211", "55443322"))))
        deferred = bl.Deferred()
        files = bl.CandidateFiles(*(str(d / n) for n in ("candidates", "seen", "ring", "craw",
                                                        "analysis", "preview", "meters")),
                                  deferred=deferred if name == "deferred" else None)
        return d, files, deferred

    def test_deferred_refreshes_leave_what_immediate_ones_leave(self):
        sequence = [("11223344", ""), ("22334455", "(QDS) Qundis"), ("11223344", ""),
                    ("33445566", ""), ("11223344", "(BMT) Bmeters"), ("22334455", "")]
        results = {}
        for name in ("immediate", "deferred"):
            d, files, deferred = self._deferred_site(name)
            registered = (d / "candidates").read_text()
            self.clock[0] = 1790935200.0
            for meter, mf in sequence:
                self.clock[0] += 3
                self.assertTrue(bl.candidate_seen_refresh(files, meter, "drv", "Water meter (0x07)", mf))
            if name == "deferred":
                self.assertEqual((d / "candidates").read_text(), registered)  # until written
                self.assertFalse((d / "analysis").exists())
                deferred.flush()
            results[name] = {n: (d / n).read_text() for n in ("candidates", "seen", "craw", "analysis")}
        self.assertEqual(results["deferred"], results["immediate"])

    def test_deferred_refresh_keeps_a_row_another_writer_changed_or_removed(self):
        d, files, deferred = self._deferred_site("deferred")
        for meter in ("11223344", "22334455"):
            self.assertTrue(bl.candidate_seen_refresh(files, meter, "drv", "Water meter (0x07)"))
        # Before the write: bash reclassifies one candidate and another one is removed.
        (d / "candidates").write_text("33445566\tdrv\tWater meter (0x07)\tT\t1\t0\t1\t1\tQDS\n"
                                      "11223344\tizarv2\tWater meter (0x07)\tB\t1\t0\t1\t1\t\n")
        deferred.flush()
        self.assertEqual((d / "candidates").read_text(),
                         "33445566\tdrv\tWater meter (0x07)\tT\t1\t0\t1\t1\tQDS\n"
                         "11223344\tizarv2\tWater meter (0x07)\tB\t1\t0\t1\t1\t\n")
        self.assertFalse((d / "analysis").exists())
        self.assertFalse((d / "craw").exists())
        self.assertEqual(len((d / "seen").read_text().splitlines()), 2)  # the receptions stay

    def test_deferred_refreshes_rewrite_each_file_once_per_write(self):
        d, files, deferred = self._deferred_site("deferred")
        for step in range(30):
            self.clock[0] += 1
            meter = ("11223344", "22334455", "33445566")[step % 3]
            bl.candidate_seen_refresh(files, meter, "drv", "Water meter (0x07)")
        rewrites = []
        real = bl._replace_with
        bl._replace_with = lambda path, lines: (rewrites.append(os.path.basename(path)), real(path, lines))
        try:
            deferred.flush()
        finally:
            bl._replace_with = real
        self.assertEqual(sorted(rewrites), ["analysis", "candidates", "craw"])

    def test_seen_file_is_appended_to_until_6000_rows(self):
        (self.d / "seen").write_text("".join(f"AAAAAAAA\tmeter\t{n}\n" for n in range(5999)))
        before = os.stat(self.d / "seen").st_ino
        bl.record_seen(self.files.seen, "11223344", "candidate")
        rows = (self.d / "seen").read_text().splitlines()
        self.assertEqual((len(rows), rows[0], rows[-1], os.stat(self.d / "seen").st_ino),
                         (6000, "AAAAAAAA\tmeter\t0", "11223344\tcandidate\t1790935200", before))

    def test_seen_file_is_cut_back_to_the_last_5000_rows_past_6000(self):
        (self.d / "seen").write_text("".join(f"AAAAAAAA\tmeter\t{n}\n" for n in range(6000)))
        bl.record_seen(self.files.seen, "11223344", "candidate")
        rows = (self.d / "seen").read_text().splitlines()
        self.assertEqual((len(rows), rows[0], rows[-1]),
                         (5000, "AAAAAAAA\tmeter\t1001", "11223344\tcandidate\t1790935200"))

    def test_bash_record_seen_appends_and_cuts_back_as_python_does(self):
        lib = ROOT / "rootfs" / "usr" / "bin" / "bridge-lib"
        t = int(self.clock[0])
        for start, expected_rows in ((5999, 6000), (6000, 5000)):
            for name, record in (("py", None), ("sh", "bash")):
                path = self.d / f"seen-{name}-{start}"
                path.write_text("".join(f"AAAAAAAA\tmeter\t{n}\n" for n in range(start)))
                if record is None:
                    bl.record_seen(str(path), "11223344", "candidate")
                else:
                    subprocess.run(
                        ["bash", "-c", f'source "{lib}/01-utils.sh"; source "{lib}/04-status.sh"; '
                         f'source "{lib}/05-raw.sh"; epoch_now() {{ echo {t}; }}; '
                         f'STATUS_SEEN_FILE="$1"; status_record_seen 11223344 candidate', "bash", str(path)],
                        check=True)
            py = (self.d / f"seen-py-{start}").read_text()
            self.assertEqual((self.d / f"seen-sh-{start}").read_text(), py)
            self.assertEqual(len(py.splitlines()), expected_rows)

    def test_stats_look_at_the_last_5000_rows_as_status_seen_stats(self):
        t = int(self.clock[0])
        # 1000 old rows of the meter, then 5000 newer ones: only those count.
        (self.d / "seen").write_text("".join(f"11223344\tcandidate\t{t - 90000 + 10 * n}\n" for n in range(1000))
                                     + "".join(f"11223344\tcandidate\t{t - 50000 + 10 * n}\n" for n in range(5000)))
        lib = ROOT / "rootfs" / "usr" / "bin" / "bridge-lib"
        expected = subprocess.run(
            ["bash", "-c", f'source "{lib}/01-utils.sh"; source "{lib}/04-status.sh"; '
             f'source "{lib}/05-raw.sh"; epoch_now() {{ echo {t}; }}; '
             f'STATUS_SEEN_FILE="$1"; status_seen_stats 11223344 candidate', "bash", str(self.d / "seen")],
            capture_output=True, text=True, check=True).stdout
        self.assertEqual("\t".join(map(str, bl.seen_stats(self.files.seen, "11223344"))) + "\n", expected)
        self.assertEqual(bl.seen_stats(self.files.seen, "11223344")[0], 5000)

    def test_stats_match_status_seen_stats(self):
        t = int(self.clock[0])
        (self.d / "seen").write_text("".join(f"11223344\t{k}\t{ts}\n" for k, ts in (
            ("candidate", t - 7200), ("meter", t - 3600), ("candidate", t - 3599),  # one reception
            ("candidate", t - 900), ("candidate", t - 600), ("x", "bad"),  # 900 s ago: still in 15 min
            ("candidate", t - 1))) + "22222222\tmeter\t5\n")
        lib = ROOT / "rootfs" / "usr" / "bin" / "bridge-lib"
        expected = subprocess.run(
            ["bash", "-c", f'source "{lib}/01-utils.sh"; source "{lib}/04-status.sh"; '
             f'source "{lib}/05-raw.sh"; epoch_now() {{ echo {t}; }}; '
             f'STATUS_SEEN_FILE="$1"; status_seen_stats 11223344 candidate', "bash", str(self.d / "seen")],
            capture_output=True, text=True, check=True).stdout
        self.assertEqual("\t".join(map(str, bl.seen_stats(self.files.seen, "11223344"))) + "\n", expected)
        self.assertEqual(bl.seen_stats(self.files.seen, "11223344"), (5, 1800, 3, 4))

    def test_row_keeps_the_manufacturer_and_moves_to_the_end(self):
        (self.d / "candidates").write_text("11223344\tauto\tX\tT\t1\t0\t0\t0\t(SAP) Diehl Metering\n"
                                           "55555555\tauto\tY\tT\t1\t0\t0\t0\n")
        bl.upsert_candidate_row(self.files.candidates, "11223344", "auto", "Z", "NOW", (2, 30, 1, 2))
        self.assertEqual((self.d / "candidates").read_text(),
                         "55555555\tauto\tY\tT\t1\t0\t0\t0\n"
                         "11223344\tauto\tZ\tNOW\t2\t30\t1\t2\t(SAP) Diehl Metering\n")

    def test_analysis_uses_the_newest_ring_row_of_the_meter(self):
        sap = "1E44" + "4C30" + "44332211" + "1001A2" + "00" * 8
        (self.d / "ring").write_text(f"T1\t{len(sap)}\t{sap}\nT2\t4\tABCD\n")
        bl.analyze_candidate_from_text(self.files, "11223344", "Unknown meter type (0x01)")
        self.assertEqual((self.d / "craw").read_text(), f"11223344\tT1\t{len(sap)}\t{sap.lower()}\n")
        f = (self.d / "analysis").read_text().rstrip("\n").split("\t")
        self.assertEqual(f[:6], ["11223344", "unknown",
                                 "RAW was mapped to this candidate, but no backend security parser has classified AES yet",
                                 "a2", "", str(len(sap))])


class ListenBookTest(unittest.TestCase):
    """parse_listen_candidates: blocks, the official-meter gate and what goes to bash."""

    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        d = Path(self.dir.name)
        self.d = d
        (d / "preview").mkdir()
        (d / "meters").mkdir()
        (d / "count").write_text("1\n")
        (d / "snippets").write_text("")
        (d / "candidates").write_text("")
        self.args = bl._parser().parse_args([
            "listen", *(f"--{n}-file={d / n}" for n in (
                "candidates", "seen", "recent-raw", "candidate-raw", "candidate-analysis")),
            f"--snippet-file={d / 'snippets'}", f"--official-count-file={d / 'count'}",
            f"--meter-dir={d / 'meters'}", f"--preview-meter-dir={d / 'preview'}",
            "--official-count-default=0", "--search-mode=false", "--search-expected=0"])
        self.out = io.StringIO()
        self.err = io.StringIO()

    def feed(self, text: str, **overrides):
        for k, v in overrides.items():
            setattr(self.args, k, v)
        book = bl.ListenBook(self.args, self.out, self.err)
        bl.run_listen(book, io.BytesIO(text.encode()), self.err)
        return [ln.split("\x1f") for ln in self.out.getvalue().splitlines()]

    BLOCKS = ("Received telegram from: 2156b4c2\n"
              "          manufacturer: (SAP) Diehl Metering\n"
              "                  type: Water meter (0x07)\n"
              "                driver: izarv2\n"
              "Received telegram from: 12345678\n"
              "                  type: Electricity meter (0x02) encrypted\n"
              "Received telegram from: 44556677\n"
              "                driver: unknown!\n")

    def test_blocks_are_handed_over_with_empty_fields_kept(self):
        self.assertEqual(self.feed(self.BLOCKS), [
            ["snippet", "2156B4C2", "izarv2", "Water meter (0x07)", "(SAP) Diehl Metering"],
            ["snippet", "44556677", "unknown", "", ""]])  # no driver: line, no booking

    def test_nothing_is_booked_without_official_meters(self):
        (self.d / "count").write_text("0\n")
        self.assertEqual(self.feed(self.BLOCKS), [])
        (self.d / "count").unlink()  # missing file: the count bash had at start
        self.assertEqual(len(self.feed(self.BLOCKS, official_count_default="2")), 2)

    def test_search_and_json_go_to_bash(self):
        json_line = '{"_":"telegram","id":"52632878","total_m3":1.5}'
        self.assertEqual(self.feed(json_line + "\n" + self.BLOCKS, search_mode="true", search_expected="12.5"), [
            ["json", json_line],
            ["search", "2156B4C2", "izarv2", "Water meter (0x07)"],
            ["search", "44556677", "unknown", ""]])

    def test_unterminated_last_line_is_not_read(self):
        self.assertEqual(self.feed("Received telegram from: 2156B4C2\n                driver: izarv2"), [])


class DeferredTest(unittest.TestCase):
    """Per-message tables written at most every FLUSH_EVERY_S, with the same bytes."""

    BASE = RxBookTest.BASE
    NAMES = ("reception", "mode", "history", "sequence", "boots", "clock")

    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.d = Path(self.dir.name)
        self.clock = [1_790_935_210.0]
        self.addCleanup(setattr, bl, "now", bl.now)
        bl.now = lambda: self.clock[0]

    def rx(self, sub: str) -> "bl.RxBook":
        (self.d / sub).mkdir()
        return bl.RxBook(*(str(self.d / sub / n) for n in self.NAMES))

    def message(self, n: int):
        return (f"wmbus/b{n % 3}/rx".encode(),
                ("{" + self.BASE + f',"seq":{n},"mode":"{"TC"[n % 2]}1"' + "}").encode())

    def test_rows_wait_five_seconds_then_match_writing_per_message(self):
        batched, each = self.rx("batched"), self.rx("each")
        for n in range(1, 31):  # 3 messages per second, 10 s
            batched(*self.message(n))
            batched.deferred.flush_if_due()
            each(*self.message(n))
            each.deferred.flush()
            if n == 14:  # 4.33 s after the first message: nothing written yet
                self.assertFalse((self.d / "batched" / "reception").exists())
            if n == 17:  # 5.33 s: written, and the same as per message
                self.assertEqual((self.d / "batched" / "reception").read_bytes(),
                                 (self.d / "each" / "reception").read_bytes())
            self.clock[0] += 1 / 3
        batched.deferred.flush()
        for name in self.NAMES:
            self.assertEqual((self.d / "batched" / name).read_bytes(),
                             (self.d / "each" / name).read_bytes(), name)

    def test_rows_are_written_when_no_further_message_arrives(self):
        bl.now = time.time
        self.addCleanup(setattr, bl, "FLUSH_EVERY_S", bl.FLUSH_EVERY_S)
        bl.FLUSH_EVERY_S = 0.2
        book = self.rx("idle")
        r, w = os.pipe()
        loop = threading.Thread(target=bl.run, args=(book, os.fdopen(r, "rb"), io.StringIO()))
        loop.start()
        try:
            topic, payload = self.message(1)
            os.write(w, topic + b"\t" + payload + b"\n")
            reception = self.d / "idle" / "reception"
            deadline = time.time() + 5
            while not reception.exists() and time.time() < deadline:
                time.sleep(0.05)
            self.assertTrue(reception.exists(), "not written while the input stayed open")
        finally:
            os.close(w)
            loop.join(5)

    def test_sigterm_writes_what_is_collected_and_exits_143(self):
        (self.d / "term").mkdir()
        files = [f"--{n}-file={self.d / 'term' / n}" for n in self.NAMES]
        proc = subprocess.Popen([sys.executable, str(ROOT / "rootfs/usr/bin/bridge_ledger.py"), "rx", *files],
                                stdin=subprocess.PIPE, stderr=subprocess.PIPE)
        for n in (1, 2, 3):
            topic, payload = self.message(n)
            proc.stdin.write(topic + b"\t" + payload + b"\n")
        proc.stdin.flush()
        history = self.d / "term" / "history"
        deadline = time.time() + 10
        while (not history.exists() or len(history.read_text().splitlines()) < 3) and time.time() < deadline:
            time.sleep(0.05)
        self.assertFalse((self.d / "term" / "reception").exists())  # still collected
        proc.terminate()
        self.assertEqual(proc.wait(10), 143)
        rows = (self.d / "term" / "reception").read_text().splitlines()
        self.assertEqual([r.split("\t")[4] for r in rows], ["1", "1", "1"])
        self.assertEqual(len((self.d / "term" / "sequence").read_text().splitlines()), 3)
        proc.stdin.close()
        proc.stderr.close()


class RecentRawRingTest(RawBookRequestTest):
    """status_recent_raw.tsv: appended to, cut back to 200 rows above 400."""

    def test_ring_is_appended_and_cut_back(self):
        ring = self.d / "recent-raw"
        for n in range(401):
            self.book.ring_append(f"ts\t4\t{n:04X}".encode())
            if n == 399:
                self.assertEqual(len(ring.read_text().splitlines()), 400)
        rows = ring.read_text().splitlines()
        self.assertEqual(len(rows), 200)
        self.assertEqual(rows[0], "ts\t4\t00C9")
        self.assertEqual(rows[-1], "ts\t4\t0190")

    def test_readers_see_the_newest_200_rows(self):
        ring = self.d / "recent-raw"
        old = self.frame("44332211")  # id 11223344, only in the oldest row
        ring.write_text(f"ts\t{len(old)}\t{old}\n" + "ts\t4\tABCD\n" * 250)
        self.assertIsNone(bl.find_recent_raw(str(ring), "11223344"))
        ring.write_text(f"ts\t{len(old)}\t{old}\n" + "ts\t4\tABCD\n" * 199)
        self.assertIsNotNone(bl.find_recent_raw(str(ring), "11223344"))


if __name__ == "__main__":
    unittest.main()
