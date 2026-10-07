"""bridge_ledger.py decode (DecodeBook) against the decode loop run_once ran
in bash (_decode_consume_bash, 12-pipeline.sh).

One recorded wmbusmeters output - every decoded golden fixture, telegrams that
carry only tariffs, only power or only an odd number, key problems, other log
lines and, for the zero-meter case, a LISTEN recording - goes through
_decode_consume_bash and through _decode_stage, each in its own data
directory, with a fake publisher that records the DEC frames it is handed.
Compared: every status file (status.json, meter table, last JSON, key
problems, receptions, events, Discovery flag, the LISTEN parser's files),
the DEC frames and the log lines. The clock is fixed on both sides.
"""
from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BRIDGE_SH = ROOT / "rootfs" / "usr" / "bin" / "bridge.sh"
LIB_DIR = ROOT / "rootfs" / "usr" / "bin" / "bridge-lib"
FIXTURES = ROOT / "tests" / "fixtures"
NOW = 1790935200
ISO = "2026-10-02T10:00:00+00:00"


def golden_lines():
    out = []
    for p in sorted(FIXTURES.glob("*/*.golden.json")):
        obj = json.loads(p.read_text())
        obj["timestamp"] = "2026-10-02T10:00:00Z"
        out.append(json.dumps(obj, separators=(",", ":")))
    return out


CORPUS = golden_lines() + [
    # Tariffs only: summed as the reading, the parts kept.
    '{"_":"telegram","media":"electricity","meter":"amiplus","name":"prad","id":"00089907",'
    '"total_energy_consumption_tariff_2_kwh":2.5,"total_energy_consumption_tariff_1_kwh":4687.858,'
    '"current_power_consumption_kw":0.3,"timestamp":"x"}',
    # Power only, after a total: the total stays.
    '{"_":"telegram","media":"electricity","meter":"amiplus","name":"prad","id":"00089907",'
    '"current_power_consumption_kw":0.4,"voltage_at_phase_1_v":231,"timestamp":"x"}',
    # Power only, no total ever: electricity shows nothing.
    '{"_":"telegram","media":"electricity","meter":"amiplus","name":"p2","id":"11223344",'
    '"current_power_consumption_kw":0.4}',
    # Instantaneous of another medium, and an odd number with its unit suffix.
    '{"_":"telegram","media":"heat","meter":"x","name":"h","id":"55667788","flow_m3h":1.25,"max_flow_m3h":9}',
    '{"_":"telegram","media":"room sensor","meter":"piigth","name":"t","id":"99887766",'
    '"temperature_c":23.52,"humidity_rh":40}',
    '{"_":"telegram","media":"heat","meter":"x","name":"h2","id":"55667799","max_flow_m3h":9,'
    '"average_flow_m3h":3,"flow_m3h":1.25}',
    '{"_":"telegram","media":"x","meter":"y","name":"z","id":"12121212","counter":5}',
    '{"_":"telegram","media":false,"meter":"y","name":false,"id":"13131313","total_m3":1}',
    '{"_":"telegram","id":"0x3264950","name":"short","total_m3":1}',
    '{"_":"telegram","id":"zz","total_m3":1}',
    '{"_":"telegram","name":"noid","total_m3":1}',
    "(wmbus) Permanently ignoring telegrams from id: 12345678 mfct: (APA) no key to decrypt",
    "(wmbus) Permanently ignoring telegrams from id: 87654321 mfct: (APA) wrong key, you need the correct decryption key",
    "(wmbus) Permanently ignoring telegrams from id: 1 something else",
    # A decoded meter clears its key problem.
    '{"_":"telegram","media":"water","meter":"x","name":"k","id":"12345678","total_m3":2}',
    "Started config rtlwmbus listening on any",
    "",
]


class FakePublisher:
    """Accepts loopback connections and records each one's bytes (DEC frames)."""

    def __init__(self, path):
        self.path = path
        self.srv = socket.socket()
        self.srv.bind(("127.0.0.1", 0))
        self.srv.listen(64)
        self.port = self.srv.getsockname()[1]
        self.frames = []
        threading.Thread(target=self.loop, daemon=True).start()

    def loop(self):
        while True:
            try:
                c, _ = self.srv.accept()
            except OSError:
                return
            data = b""
            while True:
                chunk = c.recv(65536)
                if not chunk:
                    break
                data += chunk
            c.close()
            self.frames.append(data)

    def close(self):
        self.srv.close()


class DecodeStageTests(unittest.TestCase):
    maxDiff = None

    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_side(self, side, corpus, zero, extra_excludes=""):
        d = os.path.join(self.tmp, side)
        os.makedirs(d)
        Path(d, "corpus").write_text("".join(line + "\n" for line in corpus))
        clock = os.path.join(d, "clock")
        os.makedirs(clock)
        Path(clock, "sitecustomize.py").write_text("import time\ntime.time = lambda: float(%d)\n" % NOW)
        pub = FakePublisher(os.path.join(d, "frames"))
        stage = f"_decode_consume_bash {zero}" if side == "bash" else f"_decode_stage {zero}"
        script = "\n".join([
            "set -uo pipefail",
            f"BASE='{d}/data'", "RUNTIME=\"${BASE}\"", "mkdir -p \"${BASE}\"",
            # The paths bridge.sh derives from BASE/RUNTIME.
            "while IFS= read -r _a; do _s=\"${_a#*=\\\"\\$\\{}\"; _s=\"${_s%%\\}*}\"; "
            "[[ -n \"${!_s+x}\" ]] || continue; eval \"${_a}\"; done < <(grep -E "
            f"'^[A-Z_][A-Z0-9_]*=\"\\$\\{{[A-Z_][A-Z0-9_]*\\}}[^\"$`]*\"$' '{BRIDGE_SH}')",
            *(f"source '{p}'" for p in sorted(LIB_DIR.glob("*.sh"))),
            f"BRIDGE_LEDGER='{ROOT}/rootfs/usr/bin/bridge_ledger.py'",
            "mkdir -p \"${METER_DIR}\" \"${PREVIEW_METER_DIR}\" \"${BASE}/.preview_attempts\"",
            "touch \"${STATUS_METERS_FILE}\" \"${STATUS_SEEN_FILE}\" \"${STATUS_EVENTS_FILE}\" "
            "\"${STATUS_METER_LAST_JSON_FILE}\" \"${STATUS_CANDIDATES_FILE}\" \"${SNIPPET_STATE}\"",
            "printf '12345678\\tkey_missing\\told\\n' > \"${STATUS_METER_KEY_PROBLEM_FILE}\"",
            "printf '41\\n' > \"${STATUS_RAW_COUNT_FILE}\"; printf '2026-10-02T09:59:59+00:00\\n' > \"${STATUS_LAST_RAW_FILE}\"",
            f"printf '{0 if zero == 'true' else 1}\\n' > \"${{STATUS_OFFICIAL_METERS_COUNT_FILE}}\"",
            "RAW_TOPIC='wmbus/+/telegram' STATE_PREFIX=wmbusmeters DISCOVERY_PREFIX=homeassistant",
            "SEARCH_MODE=false LOGLEVEL=normal MQTT_HOST=broker MQTT_PORT=1883 STATUS_MQTT_CONNECTED=true",
            "SEARCH_USING_TEMP_METERS=false OFFICIAL_METERS_COUNT=0",
            # What bridge.sh starts with (the pipeline's subshell inherits them).
            "STATUS_WMBUSMETERS_RUNNING=false STATUS_RAW_COUNT=0 STATUS_DECODED_COUNT=0",
            "STATUS_DISCOVERY_PUBLISHED=false STATUS_DISCOVERY_PUBLISHED_AT='' STATUS_LAST_RAW_SEEN=''",
            "STATUS_LAST_DECODED_SEEN='' STATUS_LAST_ERROR='' STATUS_LAST_EVENT=starting",
            "REQUIRE_TIMESTAMP=false STATE_RETAIN=false",
            f"MQTT_PUB_DEC=true MQTT_PUB_PORT={pub.port}",
            "METER_EXCLUDE_FIELDS[52632878]='target_*'", "METER_EXCLUDE_FIELDS[00089907]='voltage_*'",
            extra_excludes,
            f"date() {{ case \"$*\" in +%s) echo {NOW} ;; -Iseconds) echo {ISO} ;; *) command date \"$@\" ;; esac; }}",
            f"iso_now() {{ echo {ISO}; }}", f"epoch_now() {{ echo {NOW}; }}",
            f"( {stage} < '{d}/corpus' ) > '{d}/log' 2>&1",
        ])
        subprocess.run(["bash", "-c", script], check=True, timeout=300,
                       env=dict(os.environ, PYTHONPATH=clock, TZ="UTC", LEDGER_PREVIEW_IN_PYTHON="false"))
        pub.close()
        out = {"frames": pub.frames,
               "log": sorted(Path(d, "log").read_text().replace(d, "D").splitlines())}
        for root, _, files in os.walk(os.path.join(d, "data")):
            for name in files:
                if name.endswith(".lock"):
                    continue
                p = os.path.join(root, name)
                rel = os.path.relpath(p, os.path.join(d, "data"))
                text = Path(p).read_text()
                out[rel] = json.loads(text) if rel == "status.json" else text
        return out

    def compare(self, corpus, zero="false"):
        b = self.run_side("bash", corpus, zero)
        p = self.run_side("py", corpus, zero)
        self.assertEqual(sorted(p), sorted(b))
        for k in b:
            if zero == "true" and k in ("status_events.tsv", "status_seen.tsv"):
                # Written by both of bash's processes - the decode loop and
                # the zero-meter LISTEN parser it ran apart - in whatever order
                # they raced, and the events file is cut to its last 40 rows:
                # which rows survive, even a doubled one, depends on that race
                # (seen on CI). In one process they follow the input; checked
                # in test_zero_meter_listen instead.
                continue
            self.assertEqual(p[k], b[k], k)
        return p

    def test_corpus(self):
        out = self.compare(CORPUS)
        meters = out["status_meters.tsv"]
        self.assertIn("00089907\tprad\tamiplus\telectricity\ttotal_energy_consumption_kwh\t", meters)
        self.assertNotIn("12345678", out["status_meter_key_problem.tsv"])
        self.assertIn("87654321\tkey_invalid", out["status_meter_key_problem.tsv"])
        self.assertEqual(out["status.json"]["pipeline"]["decoded_count"], len(golden_lines()) + 12)
        self.assertTrue(any(b"target_*" in f for f in out["frames"]))

    def test_zero_meter_listen(self):
        listen = (FIXTURES / "listen" / "wmbusmeters-listen.txt").read_text().splitlines()
        out = self.compare(listen + CORPUS[:2], zero="true")
        announced = out.get("seen_ids.txt", "").split()
        self.assertGreater(len(announced), 5)
        events = out["status_events.tsv"].splitlines()
        detected = [e.split("	")[2].split()[2] for e in events if "	Candidate detected " in e]
        self.assertEqual(sorted(detected), sorted(set(detected)), "one event per new candidate")
        self.assertEqual(set(detected), set(announced), "every announced candidate has its event")
        self.assertEqual(sum("Decoded telegram received" in e for e in events), 2)


if __name__ == "__main__":
    unittest.main()
