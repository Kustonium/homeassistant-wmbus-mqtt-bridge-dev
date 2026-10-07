"""PreviewDecoder (bridge_ledger.py) against preview_decode_raw_if_requested
(06-candidates.sh), the one-shot decode of a candidate's preview.

Each scenario seeds two identical data directories and asks for a one-shot on
each: bash runs its function (backgrounded as in the add-on, then waited for),
Python runs PreviewDecoder.request and close(). wmbusmeters is a stub that
records the config it was given and the frame it read, and prints a scripted
output. Compared: every file and directory of the data directory (the
preview's temporary config, lock and slot must be gone), the stub's records
and the log lines. The clock is fixed on both sides.
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
sys.path.insert(0, str(ROOT / "tests"))

import bridge_ledger as bl  # noqa: E402
from test_listen_book import ISO, LIB_DIR, NAMES, NOW, seed  # noqa: E402

RAW = "1E44AE4C785634127B077A2A0000000C13" + "00" * 10     # id 12345678 (little-endian in the frame)
JSON = ('{"_":"telegram","media":"water","meter":"hydrodigit","name":"preview_12345678",'
        '"id":"12345678","total_m3":12.5,"timestamp":"2026-10-02T10:00:00Z"}')
PREVIEW = "preview/meter-preview-12345678"
PREVIEW_CFG = "name=preview_12345678\nid=12345678\n"

STUB = """#!/usr/bin/env bash
dir="${1#--useconfig=}"
{ echo "args: ${1%%=*}"; (cd "$dir" && find . | LC_ALL=C sort); cat "$dir/etc/wmbusmeters.conf";
  cat "$dir/etc/wmbusmeters.d/"*; echo "stdin:"; cat; } >> "$STUB_RECORD"
cat "$STUB_OUT"
"""


def tree(d: str) -> dict:
    """Every file (content) and directory (None) under d, lock files aside."""
    out = {}
    for root, dirs, files in os.walk(d):
        for name in dirs:
            out[os.path.relpath(os.path.join(root, name), d) + "/"] = None
        for name in files:
            if not name.endswith(".lock"):
                p = os.path.join(root, name)
                out[os.path.relpath(p, d)] = Path(p).read_bytes()
    return out


class PreviewOneShotTests(unittest.TestCase):
    def setUp(self):
        self._now, self._iso = bl.now, bl.iso_now
        bl.now = lambda: float(NOW)
        bl.iso_now = lambda: ISO
        self.tmp = tempfile.mkdtemp()
        self._env = dict(os.environ)

    def tearDown(self):
        bl.now, bl.iso_now = self._now, self._iso
        os.environ.clear()
        os.environ.update(self._env)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def side(self, name, side, extra, output):
        d = os.path.join(self.tmp, name, side)
        seed(d, extra)
        for sub in (".preview_decode_locks", ".preview_decode_last", ".preview_decode_slots"):
            os.makedirs(os.path.join(d, sub), exist_ok=True)
        for path, data in (extra or {}).items():
            if path.endswith("/"):
                os.makedirs(os.path.join(d, path), exist_ok=True)
        stub = os.path.join(self.tmp, name, f"{side}.stub")
        Path(stub).write_text(STUB)
        os.chmod(stub, 0o755)
        Path(stub + ".out").write_text(output)
        return d, stub

    def compare(self, name, raw=RAW, hint="12345678", output=JSON + "\n", extra=None, env=None):
        extra = dict(extra or {})
        extra.setdefault(PREVIEW, PREVIEW_CFG)
        extra = {k: v for k, v in extra.items() if v is not None}
        env = env or {}
        b, stub_b = self.side(name, "bash", {k: v for k, v in extra.items() if not k.endswith("/")}, output)
        p, stub_p = self.side(name, "py", {k: v for k, v in extra.items() if not k.endswith("/")}, output)
        for d in (b, p):
            for k in extra:
                if k.endswith("/"):
                    os.makedirs(os.path.join(d, k), exist_ok=True)
        # bash
        env_lines = [f"{k}='{os.path.join(b, v)}'" for k, v in NAMES.items()]
        script = "\n".join([
            "set -uo pipefail",
            *(f"source '{x}'" for x in sorted(LIB_DIR.glob("*.sh"))),
            f"BASE='{b}'", f"RUNTIME='{b}'", f"METER_DIR='{b}/meters'", f"PREVIEW_METER_DIR='{b}/preview'",
            *env_lines, "LOGLEVEL=debug",
            f"date() {{ case \"$*\" in +%s) echo {NOW} ;; -Iseconds) echo {ISO} ;; *) command date \"$@\" ;; esac; }}",
            f"iso_now() {{ echo {ISO}; }}", f"epoch_now() {{ echo {NOW}; }}",
            "write_status_json() { :; }", "mqtt_pub() { :; }",
            # The function with the stub in place of the decoder.
            f"eval \"$(declare -f preview_decode_raw_if_requested | sed 's#/usr/bin/wmbusmeters#{stub_b}#')\"",
            f"preview_decode_raw_if_requested '{raw}' '{hint}'", "wait",
        ])
        r = subprocess.run(["bash", "-c", script], capture_output=True, timeout=60,
                           env=dict(os.environ, STUB_RECORD=stub_b + ".rec", STUB_OUT=stub_b + ".out", **env))
        log_b = (r.stdout + r.stderr).decode().replace(b, "D").splitlines()
        # Python
        os.environ.update(env)
        os.environ["STUB_RECORD"], os.environ["STUB_OUT"] = stub_p + ".rec", stub_p + ".out"
        os.environ["WMBUSMETERS_ONESHOT_BIN"] = stub_p
        err = io.StringIO()
        files = bl.CandidateFiles(*(os.path.join(p, NAMES[k]) for k in (
            "STATUS_CANDIDATES_FILE", "STATUS_SEEN_FILE", "STATUS_RECENT_RAW_FILE",
            "STATUS_CANDIDATE_RAW_FILE", "STATUS_CANDIDATE_ANALYSIS_FILE")),
            os.path.join(p, "preview"), os.path.join(p, "meters"))
        requests = []
        dec = bl.PreviewDecoder(files, p, os.path.join(p, NAMES["STATUS_CANDIDATE_PREVIEW_STATE_FILE"]),
                                os.path.join(p, ".preview_attempts"),
                                os.path.join(p, NAMES["STATUS_CANDIDATE_VALUES_FILE"]),
                                os.path.join(p, NAMES["STATUS_EVENTS_FILE"]), "debug",
                                lambda level, msg: print(f"[wmbus-bridge] {msg}", file=err)
                                if level in ("info", "debug", "verbose") else None,
                                lambda *f: requests.append(f))
        dec.request(raw, hint)
        dec.close()
        log_p = err.getvalue().replace(p, "D").splitlines()
        self.assertEqual(tree(p), tree(b), f"{name}: data directory")
        rec = lambda path, d: (Path(path).read_text().replace(d, "D")  # noqa: E731
                               if os.path.exists(path) else None)
        self.assertEqual(rec(stub_p + ".rec", p), rec(stub_b + ".rec", b), f"{name}: what the decoder got")
        self.assertEqual(sorted(log_p), sorted(log_b), f"{name}: log lines")
        self.assertEqual(requests, [], f"{name}: nothing is handed to bash")
        return tree(p), rec(stub_p + ".rec", p)

    def test_decoded(self):
        files, rec = self.compare("decoded")
        self.assertIn(b"decoded_value", files[NAMES["STATUS_CANDIDATE_PREVIEW_STATE_FILE"]])
        self.assertIn("stdin:\n" + RAW + "\n", rec)
        self.assertFalse([k for k in files if ".preview_decode." in k], "temporary config removed")

    def test_variants(self):
        self.compare("no_json", output="Received telegram from: 12345678\n")
        self.compare("third_attempt", output="nothing\n",
                     extra={".preview_attempts/12345678": f"2\t{NOW - 100}\n"})
        self.compare("third_attempt_too_soon", output="nothing\n",
                     extra={".preview_attempts/12345678": f"2\t{NOW - 10}\n"})
        self.compare("throttled", extra={".preview_decode_last/12345678": f"{NOW - 5}\n"})
        self.compare("decoded_recently", extra={
            ".preview_decode_last/12345678": f"{NOW - 100}\n",
            NAMES["STATUS_CANDIDATE_PREVIEW_STATE_FILE"]: f"12345678\tdecoded_value\t{ISO}\t\n"})
        self.compare("decoded_long_ago", extra={
            ".preview_decode_last/12345678": f"{NOW - 400}\n",
            NAMES["STATUS_CANDIDATE_PREVIEW_STATE_FILE"]: f"12345678\tdecoded_value\t{ISO}\t\n"})
        self.compare("pending_after_20s", extra={
            ".preview_decode_last/12345678": f"{NOW - 25}\n",
            NAMES["STATUS_CANDIDATE_PREVIEW_STATE_FILE"]: f"12345678\tpending\t{ISO}\t\n"})
        self.compare("locked", extra={".preview_decode_locks/12345678/": ""})
        self.compare("no_slot", extra={".preview_decode_slots/1/": "", ".preview_decode_slots/2/": ""})
        self.compare("one_slot_env", extra={".preview_decode_slots/1/": ""},
                     env={"PREVIEW_DECODE_MAX_PARALLEL": "1"})
        self.compare("no_preview_config", extra={PREVIEW: None})
        self.compare("id_from_preview_files", hint="")
        self.compare("bad_raw", raw="zz-not-hex")
        self.compare("spaces_lower", raw=" " + RAW.lower()[:20] + " " + RAW.lower()[20:] + "\n")
        self.compare("heals_driver", output=JSON.replace('"meter":"hydrodigit",', '') + "\n",
                     extra={NAMES["STATUS_CANDIDATES_FILE"]:
                            "12345678\tqwaterv2\tWater meter (0x07)\tOLD\t1\t0\t1\t1\t\n"})
        self.compare("driver_changes_preview", output=JSON.replace("hydrodigit", "izarv2") + "\n")
        self.compare("json_after_a_log_line", output='(debug) {"_":"telegram","id":"12345678","total_m3":1}\n'
                                                     + JSON + "\n")
        self.compare("no_number", output='{"_":"telegram","id":"12345678","meter":"x","status":"OK"}\n')


class WakeTests(unittest.TestCase):
    """The RAW stage books a one-shot's result while its input stays quiet:
    the decoder wakes the loop; at the end of the input it is waited for."""

    def test_result_booked_without_further_input(self):
        import threading
        import time
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        seed(d, {PREVIEW: PREVIEW_CFG,
                 NAMES["STATUS_CANDIDATE_PREVIEW_STATE_FILE"]: f"12345678\tpending\t{ISO}\t\n"})
        stub = os.path.join(d, "stub")
        Path(stub).write_text("#!/usr/bin/env bash\ncat > /dev/null; sleep 0.5; echo '" + JSON + "'\n")
        os.chmod(stub, 0o755)
        env = dict(os.environ)
        self.addCleanup(lambda: (os.environ.clear(), os.environ.update(env)))
        os.environ["WMBUSMETERS_ONESHOT_BIN"] = stub
        p = lambda n: os.path.join(d, n)  # noqa: E731
        a = bl._parser().parse_args([
            "raw", f"--raw-count-file={p('raw_count')}", f"--last-raw-file={p('last_raw')}",
            f"--recent-raw-file={p(NAMES['STATUS_RECENT_RAW_FILE'])}", f"--broker-error-file={p('be')}",
            f"--candidates-file={p(NAMES['STATUS_CANDIDATES_FILE'])}",
            f"--events-file={p(NAMES['STATUS_EVENTS_FILE'])}", f"--rate-file={p('rate')}",
            f"--rate-history-file={p('rh')}", f"--status-json-file={p('status.json')}",
            f"--discovery-flag-file={p('df')}", f"--seen-file={p(NAMES['STATUS_SEEN_FILE'])}",
            f"--candidate-raw-file={p(NAMES['STATUS_CANDIDATE_RAW_FILE'])}",
            f"--candidate-analysis-file={p(NAMES['STATUS_CANDIDATE_ANALYSIS_FILE'])}",
            f"--meter-dir={p('meters')}", f"--preview-meter-dir={p('preview')}",
            f"--preview-last-dir={p('.preview_decode_last')}",
            f"--preview-state-file={p(NAMES['STATUS_CANDIDATE_PREVIEW_STATE_FILE'])}",
            f"--preview-attempts-dir={p('.preview_attempts')}", f"--preview-oneshot-runtime={d}",
            f"--candidate-values-file={p(NAMES['STATUS_CANDIDATE_VALUES_FILE'])}"])
        out = io.StringIO()
        book = bl.RawBook(a, out=out)
        self.assertIsNotNone(book.decoder)
        r, w = os.pipe()
        stream = os.fdopen(r, "rb", buffering=0)
        loop = threading.Thread(target=bl.run_lines, args=(book, stream, io.StringIO()))
        loop.start()
        os.write(w, (RAW + "\n").encode())
        state = Path(p(NAMES["STATUS_CANDIDATE_PREVIEW_STATE_FILE"]))
        deadline = time.time() + 10
        while time.time() < deadline and b"decoded_value" not in state.read_bytes():
            time.sleep(0.05)
        self.assertIn(b"decoded_value", state.read_bytes(), "booked while the input stayed open")
        # A one-shot still running when the input ends is waited for.
        Path(p(NAMES["STATUS_CANDIDATE_PREVIEW_STATE_FILE"])).write_text(f"12345678\tpending\t{ISO}\t\n")
        Path(p(".preview_decode_last/12345678")).write_text("0\n")
        os.write(w, (RAW + "\n").encode())
        time.sleep(0.1)
        os.close(w)
        loop.join(15)
        stream.close()
        self.assertFalse(loop.is_alive())
        self.assertIn(b"decoded_value", state.read_bytes(), "booked at the end of the input")
        self.assertEqual(os.listdir(p(".preview_decode_locks")), [])
        self.assertEqual(os.listdir(p(".preview_decode_slots")), [])
        self.assertNotIn("preview", out.getvalue(), "nothing is handed to bash")


if __name__ == "__main__":
    unittest.main()
