#!/usr/bin/env python3
"""external_instance.py: the external instance's lines reach the decode
pipeline whole, and nothing it does can stall or end the main one."""

import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOL = str(ROOT / "rootfs" / "usr" / "bin" / "external_instance.py")


def jline(tag, i, size):
    return json.dumps({"_": "telegram", "id": f"{tag}{i:07d}", "pad": "x" * size}) + "\n"


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.fifo = str(self.dir / "external.fifo")
        self.status = str(self.dir / "status.json")

    def tearDown(self):
        self.tmp.cleanup()

    def forward(self, data, timeout=10):
        return subprocess.run([sys.executable, TOOL, "forward", f"--fifo={self.fifo}",
                               f"--status={self.status}"], input=data, capture_output=True,
                              timeout=timeout)


class Forward(Base):
    def test_no_reader_drops_lines_instead_of_waiting(self):
        os.mkfifo(self.fifo)
        t0 = time.time()
        p = self.forward(jline("e", 1, 10).encode() * 50 + b"__EXTERNAL_RC__ 0\n")
        self.assertLess(time.time() - t0, 5)
        self.assertEqual(p.returncode, 0)
        st = json.loads(Path(self.status).read_text())
        self.assertEqual((st["state"], st["last_rc"], st["dropped"], st["telegrams"]), ("exited", 0, 50, 0))

    def test_exit_code_and_chatter(self):
        p = self.forward(b"(wmbus) started config\n\n__EXTERNAL_RC__ 139\n")
        self.assertEqual(p.returncode, 139)
        err = p.stderr.decode()
        self.assertIn("[external] (wmbus) started config", err)
        self.assertIn("external wmbusmeters ended (rc=139)", err)
        self.assertEqual(json.loads(Path(self.status).read_text())["last_rc"], 139)


class Merge(Base):
    def test_long_lines_from_both_sides_arrive_whole(self):
        # Lines far above PIPE_BUF (4096) from the main instance and through
        # the FIFO at the same time.
        main = [jline("m", i, 70000 if i % 3 == 0 else 50) for i in range(60)]
        ext = [jline("e", i, 90000 if i % 2 == 0 else 30) for i in range(60)]
        merger = subprocess.Popen([sys.executable, TOOL, "merge", f"--fifo={self.fifo}"],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        for _ in range(100):
            if os.path.exists(self.fifo):
                break
            time.sleep(0.05)
        out = []
        reader = threading.Thread(target=lambda: out.append(merger.stdout.read()))
        reader.start()
        fwd = subprocess.Popen([sys.executable, TOOL, "forward", f"--fifo={self.fifo}",
                                f"--status={self.status}"], stdin=subprocess.PIPE,
                               stderr=subprocess.PIPE)

        def feed_ext():
            for ln in ext:
                fwd.stdin.write(ln.encode())
                fwd.stdin.flush()
            fwd.stdin.close()
        t = threading.Thread(target=feed_ext)
        t.start()
        for ln in main:
            merger.stdin.write(ln.encode())
            merger.stdin.flush()
        t.join(30)
        fwd.wait(30)
        time.sleep(0.5)
        merger.stdin.close()
        merger.wait(30)
        reader.join(30)
        merger.stdout.close()
        fwd.stderr.close()
        got = out[0].decode().splitlines(keepends=True)
        self.assertEqual([ln for ln in got if '"m' in ln[:40]], main)
        self.assertEqual(sorted(ln for ln in got if '"e' in ln[:40]), sorted(ext))
        self.assertEqual(len(got), len(main) + len(ext))

    def test_merge_ends_with_its_input(self):
        p = subprocess.run([sys.executable, TOOL, "merge", f"--fifo={self.fifo}"],
                           input=b"a\nb-unterminated", capture_output=True, timeout=10)
        self.assertEqual(p.returncode, 0)
        self.assertEqual(p.stdout, b"a\nb-unterminated\n")


if __name__ == "__main__":
    unittest.main()
