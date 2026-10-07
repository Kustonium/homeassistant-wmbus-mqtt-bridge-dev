"""wmbus_meters.py against refresh_meter_files (07-meters.sh), against
sync_candidate_autodecode_files + prune_official_meter_previews and against
prune_stale_candidates + expire_stale_pending_previews (06-candidates.sh).

Each case runs refresh_meter_files and refresh_candidate_previews with
METER_FILES_IN_PYTHON=false (the bash functions) and with Python, in two
directories. Compared: every meter file, every preview config, the preview
states and attempt counters, search_status.json, the official meter count,
the log lines, the shell variables bash keeps afterwards (meter count,
SEARCH mode, exclude patterns per id) and the one-shot decodes asked for
(preview_decode_raw_if_requested, recorded).
"""
from __future__ import annotations

import datetime
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BRIDGE_SH = ROOT / "rootfs" / "usr" / "bin" / "bridge.sh"
LIB_DIR = ROOT / "rootfs" / "usr" / "bin" / "bridge-lib"
NOW = 1790935200
ISO = "2026-10-02T10:00:00+00:00"

METERS = [
    {"id": "Heat", "meter_id": "03534159", "type": "kamheat", "key": "00112233445566778899AABBCCDDEEFF",
     "calculated_fields": " total_l = total_m3 * 1000 ;bad name=1; x=;=y;noeq",
     "static_fields": "apartment = 12 b; floor=3;", "exclude_fields": "a_*,b"},
    {"id": "izar", "meter_id": "2156b4c2", "type": "auto", "key": ""},
    {"id": "dup", "meter_id": "03534159"},  # same id: keeps the first one's patterns
    {"id": "badkey", "meter_id": "11111111", "key": "1234"},
    {"id": "hexlen", "meter_id": "11111112", "key": "zz" * 16},  # 32 characters, not hex
    {"id": "other", "meter_id": "22222222", "type": "other"},
    {"id": "other2", "meter_id": "0x3264950", "type": "other", "type_other": "hydrodigit",
     "exclude_fields": "x y"},
    {"id": "noid", "meter_id": "zz"},
    {"id": "nullkey", "meter_id": "33333333", "key": None, "type": None, "exclude_fields": None},
    {"meter_id": "44444444", "type": "", "calculated_fields": "nl=a\nb"},
    {"id": 7, "meter_id": 52632878, "static_fields": None},
    {"id": "nested", "meter_id": "55555555", "type": {"a": 1}},
    {"id": "tail\n\n", "meter_id": "66666666"},  # $(...) drops the trailing newlines
    None,
    "text",
    5,
    [1],
    True,
]

CANDIDATES = "".join(row + "\n" for row in [
    # id, driver, type, last seen, ...
    "21031894\tevo868\tCold water meter (0x16)\t2026-10-02T09:00:00+00:00\t1\t0\t1\t1\t",
    "03264950\thydrodigit\tWater meter (0x07)\t2026-10-02T09:00:00+00:00\t1\t0\t1\t1\t",  # official
    "52632878\tqwaterv2\tWater meter (0x07)\t2026-10-02T09:00:00+00:00\t1\t0\t1\t1\t",   # official
    "24360570\tauto\tWater meter (0x07) encrypted\t2026-10-02T09:00:00+00:00\t1\t0\t1\t1\t",
    "03314055\tunknown\tCold water (0x72)\t2026-10-02T09:00:00+00:00\t1\t0\t1\t1\t",
    "67433753\tmkradio4\tHeat Cost Allocator (0x80)\t2026-10-02T09:00:00+00:00\t1\t0\t1\t1\t",
    "zz\tauto\tx",
    # An empty driver: IFS=$'\t' read collapses the tabs, the type becomes the driver.
    "21031895\t\tWater meter (0x07)\t2026-10-02T09:00:00+00:00",
    "\t\t",
]) + "12345678\tauto\tunterminated"

RECENT_RAW = "".join(row + "\n" for row in [
    "2026-10-02T09:59:00+00:00\t40\t1e44ae4c94180321167a",   # 21031894 (LE 94180321)
    "2026-10-02T09:59:01+00:00\t40\t1e44ae4c53376743801b",   # 67433753
])

PREVIEWS = {
    # Unchanged: nothing written, no state.
    "meter-preview-67433753": "name=preview_67433753\nid=67433753\ndriver=mkradio4\n",
    # A driver that changed.
    "meter-preview-03314055": "name=preview_03314055\nid=03314055\ndriver=old\n",
    # Now official meters: removed with their attempt counters.
    "meter-preview-03264950": "x\n",
    "meter-preview-2156B4C2": "x\n",
    # Encrypted: removed.
    "meter-preview-24360570": "x\n",
}


class MeterFilesTests(unittest.TestCase):
    maxDiff = None

    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_side(self, side, options, extra="", candidates=True, search_cache=None, loglevel="normal"):
        d = os.path.join(self.tmp, side)
        data = os.path.join(d, "data")
        os.makedirs(data)
        if options is not None:
            Path(data, "options.json").write_text(options if isinstance(options, str) else json.dumps(options))
        if candidates:
            Path(data, "status_candidates.tsv").write_text(CANDIDATES)
            Path(data, "status_recent_raw.tsv").write_text(RECENT_RAW)
            os.makedirs(os.path.join(data, "preview", "etc", "wmbusmeters.d"))
            os.makedirs(os.path.join(data, ".preview_attempts"))
            for name, text in PREVIEWS.items():
                Path(data, "preview", "etc", "wmbusmeters.d", name).write_text(text)
                Path(data, ".preview_attempts", name.rsplit("-", 1)[1]).write_text("2 1790935000\n")
        if search_cache is not None:
            Path(data, "search_candidates.tsv").write_text(search_cache)
        clock = os.path.join(d, "clock")
        os.makedirs(clock)
        Path(clock, "sitecustomize.py").write_text("import time\ntime.time = lambda: float(%d)\n" % NOW)
        script = "\n".join([
            "set -uo pipefail",
            f"BASE='{data}'", "RUNTIME=\"${BASE}\"",
            # The paths bridge.sh derives from BASE/RUNTIME.
            "while IFS= read -r _a; do _s=\"${_a#*=\\\"\\$\\{}\"; _s=\"${_s%%\\}*}\"; "
            "[[ -n \"${!_s+x}\" ]] || continue; eval \"${_a}\"; done < <(grep -E "
            f"'^[A-Z_][A-Z0-9_]*=\"\\$\\{{[A-Z_][A-Z0-9_]*\\}}[^\"$`]*\"$' '{BRIDGE_SH}')",
            *(f"source '{p}'" for p in sorted(LIB_DIR.glob("*.sh"))),
            "OPTIONS_JSON=\"${BASE}/options.json\"",
            "mkdir -p \"${METER_DIR}\" \"${PREVIEW_METER_DIR}\"",
            "echo stale > \"${METER_DIR}/meter-0042\"",
            f"LOGLEVEL={loglevel} SEARCH_MODE=false SEARCH_EXPECTED_VALUE_M3=0 SEARCH_TOLERANCE_M3=0.05",
            "SEARCH_USING_TEMP_METERS=keep SEARCH_TEMP_METERS_LOADED=9 OFFICIAL_METERS_COUNT=5",
            "SEARCH_IGNORED_COUNT=0 SEARCH_CHECKED_VALUES=0 SEARCH_DECODED_JSON_COUNT=0 SEARCH_MATCH_COUNT=0",
            "SEARCH_LAST_REASON=starting",
            "METER_EXCLUDE_FIELDS[stale]=kept",
            extra,
            f"date() {{ case \"$*\" in +%s) echo {NOW} ;; -Iseconds) echo {ISO} ;; *) command date \"$@\" ;; esac; }}",
            f"iso_now() {{ echo {ISO}; }}", f"epoch_now() {{ echo {NOW}; }}",
            "preview_decode_raw_if_requested() { printf 'PREVIEW %s %s\\n' \"$1\" \"$2\" >> \"${BASE}/previews\"; }",
            f"export METER_FILES_IN_PYTHON={'false' if side == 'bash' else 'true'}",
            "{ refresh_meter_files; refresh_candidate_previews; } > \"${BASE}/log\" 2>&1",
            "{ echo \"count=${OFFICIAL_METERS_COUNT} temp=${SEARCH_USING_TEMP_METERS} "
            "loaded=${SEARCH_TEMP_METERS_LOADED}\"; for k in \"${!METER_EXCLUDE_FIELDS[@]}\"; do "
            "printf 'exclude [%s]=[%s]\\n' \"$k\" \"${METER_EXCLUDE_FIELDS[$k]}\"; done | sort; } > \"${BASE}/vars\"",
        ])
        subprocess.run(["bash", "-c", script], check=True, timeout=120,
                       env=dict(os.environ, PYTHONPATH=clock, TZ="UTC"))
        out = {}
        for root, _, files in os.walk(data):
            for name in files:
                if name.endswith(".lock"):
                    continue
                rel = os.path.relpath(os.path.join(root, name), data)
                text = Path(root, name).read_text().replace(d, "D")
                if rel == "log":
                    text = sorted(text.splitlines())
                out[rel] = text
        return out

    def compare(self, options, **kw):
        b = self.run_side("bash", options, **kw)
        p = self.run_side("py", options, **kw)
        shutil.rmtree(self.tmp)
        os.makedirs(self.tmp)
        self.assertEqual(sorted(p), sorted(b))
        for k in b:
            self.assertEqual(p[k], b[k], k)
        return p

    def test_meters(self):
        out = self.compare({"meters": METERS})
        files = {k: v for k, v in out.items() if k.startswith("etc/wmbusmeters.d/")}
        self.assertNotIn("etc/wmbusmeters.d/meter-0042", files)
        self.assertIn("calculate_total_l=total_m3 * 1000", "".join(files.values()))
        self.assertIn("exclude [03534159]=[a_* b]", out["vars"])
        self.assertIn("PREVIEW", out.get("previews", ""))
        self.assertNotIn("preview/etc/wmbusmeters.d/meter-preview-03264950", out)
        self.assertNotIn("preview/etc/wmbusmeters.d/meter-preview-24360570", out)
        self.assertIn("driver=mkradio4", out["preview/etc/wmbusmeters.d/meter-preview-67433753"])

    def test_variants(self):
        cases = {
            "no_meters": {"meters": []},
            "meters_missing": {},
            "meters_null": {"meters": None},
            "meters_object": {"meters": {"a": {"id": "x", "meter_id": "12345678"}, "b": None}},
            "meters_string": {"meters": "abc"},
            "meters_number": {"meters": 2},
            "meters_negative": {"meters": -2},  # length: 2
            "meters_bool": {"meters": True},
            "all_invalid": {"meters": [{"id": "x", "meter_id": "q"}]},
            "not_an_object": [1, 2],
            "garbage": "{not json",
        }
        for name, options in cases.items():
            with self.subTest(name):
                self.compare(options)
        with self.subTest("no_options_file"):
            self.compare(None)
        with self.subTest("verbose"):
            self.compare({"meters": METERS[:3]}, loglevel="verbose")
        with self.subTest("debug"):
            self.compare({"meters": METERS[:3]}, loglevel="debug")
        with self.subTest("no_candidates"):
            self.compare({"meters": METERS[:3]}, candidates=False)

    def test_search(self):
        search = "SEARCH_MODE=true SEARCH_EXPECTED_VALUE_M3=12.5"
        cache = ("2156B4C2\tizarv2\n0x3264950\thydrodigit\nzz\tauto\n11111111\tbad-driver\n"
                 "22222222\t\n33333333\tdrv\tx\n\t\t\n44444444\tauto")
        for name, kw in {"cache": {"search_cache": cache}, "empty_cache": {"search_cache": "zz\n"},
                         "no_cache": {},
                         "expected_zero": {"search_cache": cache,
                                           "extra": "SEARCH_MODE=true SEARCH_EXPECTED_VALUE_M3=0"}}.items():
            with self.subTest(name):
                extra = kw.pop("extra", search)
                out = self.compare({"meters": []}, extra=extra, **kw)
                if name == "cache":
                    self.assertIn("temp=true loaded=5", out["vars"])
                    self.assertEqual(json.loads(out["search_status.json"])["phase"], "search")


# The python programs bash ran compare with the real clock, so the times are
# far in the past (stale) or the future (fresh).
OLD, NEW = "2020-01-01T00:00:00+00:00", "2099-01-01T00:00:00+00:00"
# A minute ago: past, but younger than every limit.
RECENT = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=60)).isoformat(timespec="seconds")
HK_CANDIDATES = "".join(row + "\n" for row in [
    f"21031894\tevo868\tCold water\t{OLD}\t1\t0\t1\t1\t",
    f"03264950\thydrodigit\tWater\t{NEW}\t1\t0\t1\t1\t",
    f"03314056\tauto\tWater\t{RECENT}\t1",
    "52632878\tqwaterv2\tWater\t2020-01-01T00:00:00\t1",   # naive: UTC
    "24360570\tauto\tWater\tnot-a-date\t1",
    "67433753\tauto\tWater\t \t1",
    "zz\tauto\tx\t2020-01-01T00:00:00+00:00",
    "",
    "03314055\tauto",
])
HK_STATES = "".join(row + "\n" for row in [
    f"21031894\tpending\t{OLD}\t",
    f"03264950\tpending\t{OLD}\t",
    f"52632878\tpending\t{NEW}\t",
    f"03314056\tpending\t{RECENT}\t",
    f"24360570\tdecoded_value\t{OLD}\t",
    f"67433753\tpending\t{OLD}\t",
    f"67433753\tdecoded_value\t{NEW}\t",  # the last row decides
    f"03314055\tpending\t 2020-01-01T00:00:00 \t",
    "zz\tpending\t2020-01-01T00:00:00+00:00\t",
    "short\tpending",
])


class HousekeepingTests(unittest.TestCase):
    """candidate_housekeeping against prune_stale_candidates + expire_stale_pending_previews."""

    maxDiff = None

    def run_side(self, root, side, extra=""):
        d = os.path.join(root, side)
        data = os.path.join(d, "data")
        os.makedirs(os.path.join(data, "preview", "etc", "wmbusmeters.d"))
        os.makedirs(os.path.join(data, ".preview_attempts"))
        Path(data, "status_candidates.tsv").write_text(HK_CANDIDATES)
        Path(data, "status_candidate_preview_state.tsv").write_text(HK_STATES)
        Path(data, "status_candidate_values.tsv").write_text(
            "".join(f"{m}\t1.5\t{OLD}\n" for m in ("21031894", "03264950", "52632878")))
        for m in ("21031894", "03264950", "52632878", "03314055"):
            Path(data, "preview", "etc", "wmbusmeters.d", f"meter-preview-{m}").write_text(f"id={m.lower()}\n")
            Path(data, ".preview_attempts", m).write_text("1 1\n")
        clock = os.path.join(d, "clock")
        os.makedirs(clock)
        Path(clock, "sitecustomize.py").write_text("import time\ntime.time = lambda: float(%d)\n" % NOW)
        script = "\n".join([
            "set -uo pipefail",
            f"BASE='{data}'", "RUNTIME=\"${BASE}\"",
            "while IFS= read -r _a; do _s=\"${_a#*=\\\"\\$\\{}\"; _s=\"${_s%%\\}*}\"; "
            "[[ -n \"${!_s+x}\" ]] || continue; eval \"${_a}\"; done < <(grep -E "
            f"'^[A-Z_][A-Z0-9_]*=\"\\$\\{{[A-Z_][A-Z0-9_]*\\}}[^\"$`]*\"$' '{BRIDGE_SH}')",
            *(f"source '{p}'" for p in sorted(LIB_DIR.glob("*.sh"))),
            "LOGLEVEL=normal", extra,
            f"iso_now() {{ echo {ISO}; }}", f"epoch_now() {{ echo {NOW}; }}",
            f"export METER_FILES_IN_PYTHON={'false' if side == 'bash' else 'true'}",
            "candidate_housekeeping > \"${BASE}/log\" 2>&1",
        ])
        subprocess.run(["bash", "-c", script], check=True, timeout=120,
                       env=dict(os.environ, PYTHONPATH=clock, TZ="UTC"))
        out = {}
        for r, _, files in os.walk(data):
            for name in files:
                if name.endswith(".lock"):
                    continue
                rel = os.path.relpath(os.path.join(r, name), data)
                text = Path(r, name).read_text().replace(d, "D")
                out[rel] = sorted(text.splitlines()) if rel == "log" else text
        return out

    def test_housekeeping(self):
        for name, extra in {"defaults": "",
                            "limits": "CANDIDATE_PRUNE_AFTER_SECONDS=7200 PREVIEW_PENDING_TIMEOUT_SECONDS=120",
                            "bad_limits": "CANDIDATE_PRUNE_AFTER_SECONDS=x PREVIEW_PENDING_TIMEOUT_SECONDS=-1"}.items():
            with self.subTest(name):
                root = tempfile.mkdtemp()
                try:
                    b = self.run_side(root, "bash", extra)
                    p = self.run_side(root, "py", extra)
                finally:
                    shutil.rmtree(root, ignore_errors=True)
                self.assertEqual(p, b)
                self.assertNotIn("21031894", p["status_candidates.tsv"])
                self.assertIn("03264950", p["status_candidates.tsv"])
                self.assertNotIn("preview/etc/wmbusmeters.d/meter-preview-21031894", p)
                self.assertIn("03264950\tno_decode_result", p["status_candidate_preview_state.tsv"])
                self.assertIn("03314056\tpending", p["status_candidate_preview_state.tsv"])
                self.assertIn("03314056", p["status_candidates.tsv"])
                self.assertIn("03314055\tno_decode_result", p["status_candidate_preview_state.tsv"])


if __name__ == "__main__":
    unittest.main()
