"""Unit tests for the shared primitives of bridge_ledger.py.

Each helper stands in for a bash helper in bridge-lib/03-tsv.sh, so where the
outcome can be compared the bash helper is run on the same input and the two
files must be byte-identical.
"""
from __future__ import annotations

import io
import os
import stat
import subprocess
import sys
import tempfile
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
            bash('_append_esp_rx_history "$1" "$2" lilygo 52632878 wmbus/lilygo/telegram', str(a), str(n))
            bl.append_locked(str(b), f'{{"time":{n},"source":"lilygo","meter_id":"52632878","topic":"wmbus/lilygo/telegram"}}')
        self.assertEqual(a.read_bytes(), b.read_bytes())
        for max_lines, keep in ((7, 3), (6, 3)):  # at the limit nothing happens; above it, trim
            with self.subTest(max_lines=max_lines):
                bash('_trim_esp_rx_history "$1" "$2" "$3"', str(a), str(max_lines), str(keep))
                bl.trim_locked(str(b), max_lines, keep)
                self.assertEqual(a.read_bytes(), b.read_bytes())
        self.assertEqual(len(b.read_bytes().splitlines()), 3)


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


if __name__ == "__main__":
    unittest.main()
