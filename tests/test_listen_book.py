"""ListenBook's registration of new and changed candidates and of decoded JSON
against the bash functions it replaces (emit_snippet_if_new and
_process_listen_json_line in 11-listen.sh, with status_candidate_seen and
ensure_candidate_autodecode in 06-candidates.sh).

Each scenario seeds two identical data directories, runs the bash function on
one and the book on the other with the same fixed clock, and compares every
file, the log lines and the preview one-shots asked for (bash:
preview_decode_raw_if_requested, stubbed; the book: its "preview" request).
"""
from __future__ import annotations

import argparse
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

import bridge_ledger as bl  # noqa: E402

LIB_DIR = ROOT / "rootfs" / "usr" / "bin" / "bridge-lib"
NOW = 1790935200
ISO = "2026-10-02T10:00:00+00:00"
OFFICIAL = "03264950"
RAW_A = "1e44ae4c785634127b077a2a0000000c13" + "00" * 10   # id 12345678 little-endian
NAMES = {
    "STATUS_CANDIDATES_FILE": "status_candidates.tsv", "STATUS_SEEN_FILE": "status_seen.tsv",
    "STATUS_RECENT_RAW_FILE": "status_recent_raw.tsv", "STATUS_CANDIDATE_RAW_FILE": "status_candidate_raw.tsv",
    "STATUS_CANDIDATE_ANALYSIS_FILE": "status_candidate_analysis.tsv", "SNIPPET_STATE": "seen_ids",
    "STATUS_EVENTS_FILE": "status_events.tsv", "STATUS_CANDIDATE_PREVIEW_STATE_FILE": "preview_state.tsv",
    "STATUS_CANDIDATE_VALUES_FILE": "status_candidate_values.tsv",
    "STATUS_OFFICIAL_METERS_COUNT_FILE": "official_count",
}


def seed(d: str, extra=None) -> None:
    os.makedirs(os.path.join(d, "meters"))
    os.makedirs(os.path.join(d, "preview"))
    os.makedirs(os.path.join(d, ".preview_attempts"))
    Path(d, "meters", "meter-0001").write_text(f"name=water\nid={OFFICIAL.lower()}\ndriver=hydrodigit\n")
    Path(d, NAMES["STATUS_OFFICIAL_METERS_COUNT_FILE"]).write_text("1\n")
    Path(d, NAMES["STATUS_CANDIDATES_FILE"]).write_text(
        "52632878\tqwaterv2\tWater meter (0x07)\tOLD\t3\t30\t1\t2\tQDS\n"
        "77665544\tauto\twMBus telegram\tOLD\t1\t0\t1\t1\t\n")
    Path(d, NAMES["STATUS_SEEN_FILE"]).write_text(f"52632878\tcandidate\t{NOW - 100}\n")
    Path(d, NAMES["STATUS_RECENT_RAW_FILE"]).write_text(f"2026-10-02T09:59:00+00:00\t{len(RAW_A)}\t{RAW_A}\n")
    Path(d, NAMES["SNIPPET_STATE"]).write_text("52632878\n")
    for name, data in (extra or {}).items():
        Path(d, name).parent.mkdir(parents=True, exist_ok=True)
        Path(d, name).write_text(data)


def dump(d: str) -> dict:
    out = {}
    for root, _, files in os.walk(d):
        for f in files:
            if f.endswith(".lock"):
                continue
            p = os.path.join(root, f)
            out[os.path.relpath(p, d)] = Path(p).read_bytes()
    return out


def run_bash(d: str, call: str) -> tuple:
    env_lines = [f"{k}='{os.path.join(d, v)}'" for k, v in NAMES.items()]
    script = "\n".join([
        "set -uo pipefail",
        *(f"source '{p}'" for p in sorted(LIB_DIR.glob("*.sh"))),
        f"BASE='{d}'", f"RUNTIME='{d}'", f"METER_DIR='{d}/meters'", f"PREVIEW_METER_DIR='{d}/preview'",
        *env_lines, "LOGLEVEL=debug", "OFFICIAL_METERS_COUNT=1",
        f"date() {{ case \"$*\" in +%s) echo {NOW} ;; -Iseconds) echo {ISO} ;; *) command date \"$@\" ;; esac; }}",
        f"iso_now() {{ echo {ISO}; }}", f"epoch_now() {{ echo {NOW}; }}",
        "write_status_json() { :; }", "mqtt_pub() { :; }",
        f"preview_decode_raw_if_requested() {{ printf '%s %s\\n' \"$2\" \"$1\" >> '{d}.oneshots'; }}",
        call,
    ])
    r = subprocess.run(["bash", "-c", script], capture_output=True, timeout=60)
    log = (r.stdout + r.stderr).decode().replace(d, "D").splitlines()
    try:
        oneshots = Path(d + ".oneshots").read_text().splitlines()
    except OSError:
        oneshots = []
    return log, oneshots


def run_python(d: str, action: str, *fields: str) -> tuple:
    a = argparse.Namespace(
        candidates_file=os.path.join(d, NAMES["STATUS_CANDIDATES_FILE"]),
        seen_file=os.path.join(d, NAMES["STATUS_SEEN_FILE"]),
        recent_raw_file=os.path.join(d, NAMES["STATUS_RECENT_RAW_FILE"]),
        candidate_raw_file=os.path.join(d, NAMES["STATUS_CANDIDATE_RAW_FILE"]),
        candidate_analysis_file=os.path.join(d, NAMES["STATUS_CANDIDATE_ANALYSIS_FILE"]),
        snippet_file=os.path.join(d, NAMES["SNIPPET_STATE"]),
        official_count_file=os.path.join(d, NAMES["STATUS_OFFICIAL_METERS_COUNT_FILE"]),
        meter_dir=os.path.join(d, "meters"), preview_meter_dir=os.path.join(d, "preview"),
        official="nonzero", official_count_default="1", search_mode="false", search_expected="0",
        loglevel="debug", events_file=os.path.join(d, NAMES["STATUS_EVENTS_FILE"]),
        preview_state_file=os.path.join(d, NAMES["STATUS_CANDIDATE_PREVIEW_STATE_FILE"]),
        preview_attempts_dir=os.path.join(d, ".preview_attempts"),
        candidate_values_file=os.path.join(d, NAMES["STATUS_CANDIDATE_VALUES_FILE"]))
    out, err = io.StringIO(), io.StringIO()
    book = bl.ListenBook(a, out=out, err=err)
    getattr(book, action)(*fields)
    book.deferred.flush()
    oneshots = [" ".join(line.split(bl.ListenBook.SEP)[2:0:-1]) for line in out.getvalue().splitlines()
                if line.startswith("preview" + bl.ListenBook.SEP)]
    return err.getvalue().replace(d, "D").splitlines(), oneshots


class ListenBookTests(unittest.TestCase):
    def setUp(self):
        self._now, self._iso = bl.now, bl.iso_now
        bl.now = lambda: float(NOW)
        bl.iso_now = lambda: ISO
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        bl.now, bl.iso_now = self._now, self._iso
        shutil.rmtree(self.tmp, ignore_errors=True)

    def compare(self, name, bash_call, action, fields, extra=None):
        b, p = os.path.join(self.tmp, name, "bash"), os.path.join(self.tmp, name, "py")
        seed(b, extra)
        seed(p, extra)
        log_b, shots_b = run_bash(b, bash_call)
        log_p, shots_p = run_python(p, action, *fields)
        self.assertEqual(dump(p), dump(b), f"{name}: files")
        self.assertEqual(sorted(log_p), sorted(log_b), f"{name}: log lines")
        self.assertEqual(shots_p, shots_b, f"{name}: preview one-shots")
        return dump(p)

    def snippet(self, name, meter, driver, type_line, manufacturer="", extra=None):
        args = " ".join(f"'{x}'" for x in (meter, driver, type_line, manufacturer))
        return self.compare(name, f"emit_snippet_if_new {args}", "snippet",
                            (meter, driver, type_line, manufacturer), extra)

    def json(self, name, line, extra=None):
        return self.compare(name, f"_process_listen_json_line '{line}'", "json", (line,), extra)

    def test_snippets(self):
        out = self.snippet("new_auto", "12345678", "auto", "Water meter (0x07)", "(QDS) Qundis")
        self.assertIn("preview/meter-preview-12345678", out)
        self.assertNotIn(b"driver=", out["preview/meter-preview-12345678"])
        self.snippet("new_driver", "12345678", "hydrodigit", "Water meter (0x07)")
        self.snippet("new_unknown", "12345678", "unknown", "")
        self.snippet("empty_driver_type", "12345678", "", "")
        self.snippet("changed_driver", "52632878", "qwaterv3", "Water meter (0x07)",
                     extra={"preview/meter-preview-52632878": "name=preview_52632878\nid=52632878\n"
                                                              "driver=qwaterv2\n"})
        self.snippet("unchanged_unannounced", "52632878", "qwaterv2", "Water meter (0x07)",
                     extra={"preview/meter-preview-52632878": "name=preview_52632878\nid=52632878\n"
                                                              "driver=qwaterv2\n", "seen_ids": ""})
        self.snippet("official", OFFICIAL, "hydrodigit", "Water meter (0x07)",
                     extra={f"preview/meter-preview-{OFFICIAL}": "x\n",
                            f".preview_attempts/{OFFICIAL}": "2\t100\n"})
        self.snippet("aes", "12345678", "kamwater", "Cold water meter (0x16) encrypted",
                     extra={"preview/meter-preview-12345678": "x\n", ".preview_attempts/12345678": "1\t1\n"})
        self.snippet("not_encrypted", "12345678", "kamwater", "Cold water meter (0x16) not encrypted")
        self.snippet("short_id", "345678", "auto", "Water meter (0x07)")
        self.snippet("bad_id", "zz", "auto", "Water meter (0x07)")
        self.snippet("attempts_dropped", "12345678", "auto", "Water meter (0x07)",
                     extra={".preview_attempts/12345678": "2\t100\n"})

    def test_json(self):
        self.json("total_m3", '{"_":"telegram","id":"12345678","meter":"hydrodigit","media":"water",'
                              '"total_m3":9.002,"total_kwh":5}')
        self.json("kwh_first", '{"_":"telegram","id":"12345678","total_kwh":5,"total_m3":9.002}')
        self.json("like", '{"_":"telegram","id":"12345678","backflow_m3":3.5,"heat_energy_mwh":1,'
                          '"volume_l":2,"target_m3":1,"energy_kwh":7.25}')
        self.json("tariffs", '{"_":"telegram","id":"12345678","meter":"amiplus",'
                             '"total_energy_consumption_tariff_1_kwh":4687.858,'
                             '"total_energy_consumption_tariff_2_kwh":0.1,"current_power_consumption_kw":0.3}')
        self.json("tariff_int", '{"_":"telegram","id":"12345678","total_energy_consumption_tariff_1_kwh":4,'
                                '"total_energy_consumption_tariff_2_kwh":6}')
        self.json("instant", '{"_":"telegram","id":"12345678","current_power_consumption_kw":0.336,"flow_m3h":2}')
        self.json("any_number", '{"_":"telegram","id":"12345678","rssi":-50,"status":1,"temperature_c":21.5}')
        self.json("no_number", '{"_":"telegram","id":"12345678","status":"OK","rssi":-50}')
        self.json("heal_driver", '{"_":"telegram","id":"52632878","total_m3":1}')
        self.json("heal_type", '{"_":"telegram","id":"77665544","meter":"izar","total_m3":1}')
        self.json("driver_key", '{"_":"telegram","id":"12345678","driver":"apator162","total_m3":1}')
        self.json("number_id", '{"_":"telegram","id":12345678,"total_m3":1}')
        self.json("bad_id", '{"_":"telegram","id":"nope","total_m3":1}')
        self.json("no_official", '{"_":"telegram","id":"12345678","meter":"x","total_m3":1}',
                  extra={"official_count": "0\n"})


if __name__ == "__main__":
    unittest.main()
