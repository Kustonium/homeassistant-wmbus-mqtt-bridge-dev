"""Tauron/KPL meters configured as amiplus: the rejection that moves them to
sanxing (07-meters.sh status_detect_key_problem -> _kpl_amiplus_rejected,
bridge_ledger.py DecodeBook.key_problem -> kpl_amiplus_rejected).

Both sides read the same wmbusmeters lines against the same meter files and
must leave the same sanxing list and the same reload request. The meter files
side (amiplus -> sanxing when listed) is in tests/test_meter_files.py.
"""
from __future__ import annotations

import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "rootfs" / "usr" / "bin"))
LIB_DIR = ROOT / "rootfs" / "usr" / "bin" / "bridge-lib"

import bridge_ledger as bl  # noqa: E402

ISO = "2026-10-02T10:00:00+00:00"
REJECT = ("(wmbus) WARNING!! decrypted content failed check, did you use the correct decryption key? "
          "Permanently ignoring telegrams from id: {id} mfct: ({mfct}) KPLC Power, Kenya (0x2e0c) "
          "type: Electricity meter (0x02) ver: 0x01")
METERS = {
    "meter-0001": "name=tauron\nid=12345678\nkey=000102030405060708090A0B0C0D0E0F\ndriver=amiplus\n",
    "meter-0002": "name=apator\nid=87654321\ndriver=amiplus\n",
    "meter-0003": "name=other\nid=11223344\ndriver=sanxing\n",
}


class KplSanxingTests(unittest.TestCase):
    maxDiff = None

    def setUp(self):
        self._iso = bl.iso_now
        bl.iso_now = lambda: ISO
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        bl.iso_now = self._iso
        shutil.rmtree(self.tmp, ignore_errors=True)

    def seed(self, side):
        d = os.path.join(self.tmp, side)
        os.makedirs(os.path.join(d, "meters"))
        for name, text in METERS.items():
            Path(d, "meters", name).write_text(text)
        return d

    def bash(self, lines):
        d = self.seed("bash")
        script = "\n".join([
            "set -uo pipefail",
            *(f"source '{p}'" for p in sorted(LIB_DIR.glob("*.sh"))),
            f"BASE='{d}'", f"METER_DIR='{d}/meters'",
            f"METER_KPL_SANXING_FILE='{d}/meter_kpl_sanxing.tsv'",
            f"STATUS_METER_KEY_PROBLEM_FILE='{d}/key_problem.tsv'",
            f"iso_now() {{ echo {ISO}; }}",
            *(f"status_detect_key_problem {subprocess.list2cmdline([ln])}" for ln in lines),
        ])
        subprocess.run(["bash", "-c", script], check=True, timeout=60, capture_output=True)
        return self.state(d)

    def python(self, lines):
        d = self.seed("py")
        a = bl._parser().parse_args([
            "decode", *(f"--{n}-file={d}/{n}" for n in (
                "status-json", "raw-count", "last-raw", "discovery-flag", "events", "meters",
                "meter-last-json", "seen")),
            f"--key-problem-file={d}/key_problem.tsv", "--publisher-port=0",
            f"--meter-dir={d}/meters", f"--kpl-sanxing-file={d}/meter_kpl_sanxing.tsv",
            f"--reload-flag-file={d}/.reload_pipeline"])
        book = bl.DecodeBook(a, out=io.StringIO(), err=io.StringIO())
        for ln in lines:
            book.key_problem(ln)
        return self.state(d)

    @staticmethod
    def state(d):
        sanxing = Path(d, "meter_kpl_sanxing.tsv")
        return (sanxing.read_text() if sanxing.exists() else None,
                os.path.exists(os.path.join(d, ".reload_pipeline")))

    def both(self, lines):
        b, p = self.bash(lines), self.python(lines)
        self.assertEqual(p, b)
        return b

    def test_amiplus_kpl_rejected_once(self):
        line = REJECT.format(id="12345678", mfct="KPL")
        listed, reload = self.both([line, line])  # the second rejection changes nothing
        self.assertEqual(listed, f"12345678\t{ISO}\n")
        self.assertTrue(reload)

    def test_left_alone(self):
        cases = {
            "other manufacturer": REJECT.format(id="87654321", mfct="APA"),
            "already sanxing": REJECT.format(id="11223344", mfct="KPL"),
            "not configured": REJECT.format(id="99999999", mfct="KPL"),
            "missing key": "(wmbus) no key to decrypt payload! Permanently ignoring telegrams from id: "
                           "12345678 mfct: (KPL) ...",
        }
        for name, line in cases.items():
            with self.subTest(name):
                shutil.rmtree(self.tmp)
                os.makedirs(self.tmp)
                self.assertEqual(self.both([line]), (None, False))


if __name__ == "__main__":
    unittest.main()
