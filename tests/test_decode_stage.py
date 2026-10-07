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

SearchStageTests: the same with search_mode on - the temporary search_<id>
meters (value check, matches, delta, the Discovery cleanup, search_status.json,
the SEARCH messages) and the collecting phase (SEARCH's candidate cache, fed
by the zero-meter LISTEN parser).
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

    def run_side(self, side, corpus, zero, extra_excludes="", extra="", seed=None, stage=None):
        d = os.path.join(self.tmp, side)
        os.makedirs(d)
        Path(d, "corpus").write_text("".join(line + "\n" for line in corpus))
        for name, text in (seed or {}).items():
            os.makedirs(os.path.dirname(os.path.join(d, "data", name)) or d, exist_ok=True)
            Path(d, "data", name).write_text(text)
        clock = os.path.join(d, "clock")
        os.makedirs(clock)
        Path(clock, "sitecustomize.py").write_text("import time\ntime.time = lambda: float(%d)\n" % NOW)
        pub = FakePublisher(os.path.join(d, "frames"))
        if stage is None:
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
            extra,
            f"date() {{ case \"$*\" in +%s) echo {NOW} ;; -Iseconds) echo {ISO} ;; *) command date \"$@\" ;; esac; }}",
            f"iso_now() {{ echo {ISO}; }}", f"epoch_now() {{ echo {NOW}; }}",
            f"( {stage} < '{d}/corpus' ) > '{d}/log' 2>&1",
        ])
        subprocess.run(["bash", "-c", script], check=True, timeout=300,
                       env=dict(os.environ, PYTHONPATH=clock, TZ="UTC", LEDGER_PREVIEW_IN_PYTHON="false",
                                LEDGER_SEARCH_IN_PYTHON="false" if side == "bash" else "true"))
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

    def compare(self, corpus, zero="false", extra="", seed=None, stage=None):
        b = self.run_side("bash", corpus, zero, extra=extra, seed=seed, stage=stage)
        p = self.run_side("py", corpus, zero, extra=extra, seed=seed, stage=stage)
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



def _search_tg(name, mid, **fields):
    obj = {"_": "telegram", "media": "water", "meter": "izarv2", "name": name, "id": mid}
    obj.update(fields)
    return json.dumps(obj, separators=(",", ":"))


SEARCH_CORPUS = [
    # In tolerance (diff 0.014): the match, then a delta on the next one.
    '{"_":"telegram","media":"water","meter":"izarv2","name":"search_2156B4C2","id":"2156B4C2",'
    '"total_m3":123.470,"target_m3":120.1,"flow_m3h":0.0,"Total_Volume_M3":123.47,"current_status":"OK",'
    '"prefix-a b":1,"__x__":2,"history":{"a":1},"months":[1,2],"rssi":-70,"status":"OK","ok":true,'
    '"timestamp":"x"}',
    _search_tg("search_2156B4C2", "2156B4C2", total_m3=123.5),
    _search_tg("search_2156B4C2", "2156B4C2", total_m3=123.6, **{"": 4}),
    # Out of tolerance, then the same value: no delta.
    _search_tg("search_11112222", "11112222", total_m3=5.0, max_flow_m3h=1e-05),
    _search_tg("search_11112222", "11112222", total_m3=5.0),
    # Below the expected value, a negative and a tiny difference.
    _search_tg("search_33334444", "33334444", total_volume=123.4561, delta_m3=-1.5E+2),
    # A temporary meter without a valid id, with a false name, a short id.
    _search_tg("search_bad", "zz", total_m3=123.456),
    '{"_":"telegram","media":false,"meter":false,"name":"search_x","id":"0x3264950","total_m3":123.456}',
    # A configured meter: checked too, then booked and published as usual.
    _search_tg("woda", "03534159", total_m3=123.44),
    _search_tg("woda_search_2", "03534160", total_m3=7),  # "search_" not at the start
    "Started config rtlwmbus listening on any",
    # A LISTEN block: while SEARCH decodes its temporary meters, the
    # zero-meter parser does not run (nothing is cached or booked from it).
    "Received telegram from: 44556677",
    "          manufacturer: (SAP) Diehl Metering, Germany (0x4c30)",
    "                  type: Water meter (0x07)",
    "                driver: izarv2",
    "Received telegram from: 44556688",
]

SEARCH_BASE = "\n".join([
    "SEARCH_MODE=true SEARCH_EXPECTED_VALUE_M3=123.456 SEARCH_TOLERANCE_M3=0.05",
    "SEARCH_DELTA_MODE=true SEARCH_MIN_DELTA_M3=0.001 SEARCH_TOPIC=wmbus/search/candidates",
    "DISCOVERY_ENABLED=true",
    "SEARCH_IGNORED_COUNT=0 SEARCH_TEMP_METERS_LOADED=0 SEARCH_CHECKED_VALUES=0",
    "SEARCH_DECODED_JSON_COUNT=0 SEARCH_MATCH_COUNT=0 SEARCH_LAST_CACHE_CHANGE=''",
    "SEARCH_LAST_CANDIDATE_ID='' SEARCH_LAST_CANDIDATE_DRIVER='' SEARCH_LAST_CANDIDATE_TYPE=''",
    "SEARCH_LAST_CHECKED_ID='' SEARCH_LAST_CHECKED_DRIVER='' SEARCH_LAST_CHECKED_FIELD=''",
    "SEARCH_LAST_CHECKED_VALUE='' SEARCH_LAST_CHECKED_DIFF='' SEARCH_LAST_IGNORED_REASON=''",
])


class SearchStageTests(DecodeStageTests):
    """_decode_stage with search_mode on against _decode_consume_bash."""

    SEED = {"search_matches.tsv": "", "search_status.json": "{}\n",
            "search_candidates.tsv": "2156B4C2\tizarv2\n11112222\tauto\n33334444\tauto\n"}

    def test_corpus(self):
        pass

    def test_zero_meter_listen(self):
        pass

    def test_temporary_meters(self):
        out = self.compare(SEARCH_CORPUS, zero="true", extra=SEARCH_BASE + "\nSEARCH_USING_TEMP_METERS=true "
                           "SEARCH_TEMP_METERS_LOADED=3 SEARCH_LAST_REASON=loaded_temp_meters",
                           seed=self.SEED)
        self.assertNotIn("44556677", out["search_candidates.tsv"] + out["status_candidates.tsv"])
        status = json.loads(out["search_status.json"])
        self.assertEqual(status["phase"], "matched")
        self.assertEqual(status["decoded_json"], 7)  # "zz" is no id, 0x3264950 is
        # 2156B4C2 twice (total_m3, Total_Volume_M3), 33334444, 03264950 and the configured meter.
        self.assertEqual(len(out["search_matches.tsv"].splitlines()), 5)
        frames = b"".join(out["frames"])
        self.assertIn(b'"event":"value_match","id":"2156B4C2"', frames)
        self.assertIn(b'"event":"delta_match"', frames)
        self.assertIn(b"homeassistant/sensor/wmbus_2156B4C2/prefix_a_b/config", frames)
        self.assertIn(b"no_aes", out["status_candidate_analysis.tsv"].encode())
        self.assertIn("03534159", out["status_meters.tsv"])
        self.assertNotIn("2156B4C2", out["status_meters.tsv"])

    def test_no_expected_value(self):
        out = self.compare(SEARCH_CORPUS, extra=SEARCH_BASE + "\nSEARCH_USING_TEMP_METERS=true "
                           "SEARCH_EXPECTED_VALUE_M3=0 SEARCH_DELTA_MODE=false DISCOVERY_ENABLED=false "
                           "SEARCH_LAST_REASON=x", seed=self.SEED)
        self.assertEqual(out["search_matches.tsv"], "")
        self.assertNotIn(b"rssi_dbm", b"".join(out["frames"]))

    def test_earlier_match(self):
        # A match of an earlier run (in the file, none counted in this one).
        seed = dict(self.SEED, **{"search_matches.tsv": "2026-10-01T10:00:00+00:00\t2156B4C2\tizarv2\twater"
                                                        "\ttotal_m3\t123.47\t123.456\t0.014000\t0.05\n"})
        out = self.compare(SEARCH_CORPUS[3:5], extra=SEARCH_BASE + "\nSEARCH_USING_TEMP_METERS=true", seed=seed)
        self.assertEqual(json.loads(out["search_status.json"])["phase"], "matched")

    def test_collecting(self):
        # SEARCH's candidate cache is fed by the zero-meter LISTEN parser. bash
        # forked it from the decode loop as >(...), which nothing waits for, so
        # bash and Python are compared on that parser's stage itself
        # (LEDGER_SEARCH_IN_PYTHON false/true), then the decode stage, which
        # runs the parser in its own process, against that result. One pass of
        # the recording: in bash the rows of a pass are written behind the
        # parser, so what the next pass finds of them (a manufacturer filled
        # in) depends on timing; 2156B4C2 is cached already.
        listen = (FIXTURES / "listen" / "wmbusmeters-listen.txt").read_text().splitlines()
        extra = SEARCH_BASE + "\nSEARCH_USING_TEMP_METERS=false SEARCH_LAST_REASON=no_cached_candidates"
        seed = {"search_matches.tsv": "", "search_status.json": "{}\n",
                "search_candidates.tsv": "2156B4C2\tizarv2\n"}
        out = self.compare(listen, zero="true", extra=extra, seed=seed,
                           stage="_listen_parse_stage zero")
        status = json.loads(out["search_status.json"])
        self.assertEqual(status["phase"], "collecting")
        self.assertGreater(status["cached_candidates"], 2)
        self.assertGreater(status["ignored_candidates"], 2)
        cached = out["search_candidates.tsv"].split()
        self.assertEqual(len(cached[::2]), len(set(cached[::2])), "each candidate cached once")
        self.assertNotIn("2156B4C2", out["status_candidates.tsv"], "a cached candidate is not booked again")
        dec = self.run_side("dec", listen, "true", extra=extra, seed=seed)
        for k in ("search_candidates.tsv", "search_status.json", "status_candidates.tsv",
                  "status_candidate_analysis.tsv", "status_candidate_preview_state.tsv"):
            self.assertEqual(dec[k], out[k], k)

    def test_collecting_one_status(self):
        # In one process the parser's candidates and the decode loop's value
        # checks share the counters (bash wrote search_status.json from both
        # processes, each with its own).
        listen = (FIXTURES / "listen" / "wmbusmeters-listen.txt").read_text().splitlines()
        out = self.run_side("py", listen + [_search_tg("woda", "03534159", total_m3=123.44)], "true",
                            extra=SEARCH_BASE + "\nSEARCH_USING_TEMP_METERS=false",
                            seed={"search_matches.tsv": "", "search_status.json": "{}\n"})
        status = json.loads(out["search_status.json"])
        self.assertGreater(status["cached_candidates"], 2)
        self.assertGreater(status["ignored_candidates"], 2)
        self.assertEqual(status["checked_values"], 1)
        self.assertEqual(status["last_checked"]["id"], "03534159")

if __name__ == "__main__":
    unittest.main()
