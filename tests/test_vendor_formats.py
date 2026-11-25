#!/usr/bin/env python3
"""vendor_formats.py: manufacturer formats described by data files.

Every shipped format must pass its own test telegrams; the engine must refuse
malformed files; the stage must publish only configured meters and keep the
fields of long and short frames together; a format wmbusmeters already
decodes must hand its meters back to wmbusmeters (wmbus_meters.py refresh).
"""

import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "rootfs" / "usr" / "bin"))

import vendor_formats as vf  # noqa: E402
import wmbus_meters as wm  # noqa: E402

FORMATS = ROOT / "rootfs" / "usr" / "share" / "wmbus-bridge" / "formats"
HC = json.loads((FORMATS / "bmeters_hydroclima_v34.json").read_text(encoding="utf-8"))
LONG_400 = HC["tests"][0]["telegram"]
SHORT_400 = HC["tests"][1]["telegram"]
LONG_445 = HC["tests"][2]["telegram"]


class ShippedFormats(unittest.TestCase):
    def test_every_file_passes_its_tests(self):
        errors = []
        formats = vf.load_formats(str(FORMATS), errors)
        self.assertEqual(errors, [])
        self.assertTrue(formats)
        for fmt in formats:
            self.assertEqual(vf.run_tests(fmt), [], fmt.path)

    def test_check_cli(self):
        out = io.StringIO()
        with mock.patch("sys.stdout", out):
            rc = vf.main(["check", f"--formats-dir={FORMATS}"])
        self.assertEqual(rc, 0, out.getvalue())

    def test_long_frame_names_follow_the_wmbusmeters_driver(self):
        # When wmbusmeters takes the format over (driver hydroclimav34), the
        # entities must keep their names: the long-frame fields are its names.
        upstream = {"allocation_hca", "target_hca", "average_ambient_temperature_c",
                    "previous_average_ambient_temperature_c"}
        for ftype in ("13", "12"):
            names = {f["name"] for f in HC["frames"][ftype]["fields"]}
            self.assertEqual(names - {"previous_month_hca"}, upstream, ftype)

    def test_a_wrong_expectation_fails(self):
        spec = json.loads(json.dumps(HC))
        spec["tests"][0]["expect"]["allocation_hca"] = 51.8
        self.assertTrue(vf.run_tests(vf.Format(spec)))


class Engine(unittest.TestCase):
    def test_expression(self):
        f = vf.compile_expr("((id0 ^ id3) << 8) | (id1 ^ id2)")
        self.assertEqual(f([0x99, 0x03, 0x24, 0x78]), 0xE127)
        self.assertEqual(vf.compile_expr("0x10 + 3 - 1")([0, 0, 0, 0]), 18)

    def test_expression_refuses_anything_else(self):
        for bad in ("__import__('os')", "id4", "id0 ** 2", "open", "id0 +", "(id0", "1; 2"):
            with self.assertRaises(vf.FormatError, msg=bad):
                vf.compile_expr(bad)

    def test_word_round_trip(self):
        fmt = vf.Format(HC)
        env = {"A": 0x7820, "D": 0xCE9A}
        for seed in range(16):
            for p in (0, 1, 517, 0x0800, 0xFFFF):
                c = fmt._encode_upto(p, seed, env, len(fmt.steps))
                self.assertEqual(fmt.decode_word(c, seed, env), p)

    def test_short_frame_needs_a_long_frame_first(self):
        fmt = vf.Format(HC)
        cache = {}
        self.assertIsNone(fmt.decode(bytes.fromhex(SHORT_400), cache))
        fmt.decode(bytes.fromhex(LONG_400), cache)
        mid, fields = fmt.decode(bytes.fromhex(SHORT_400), cache)
        self.assertEqual(mid, "78240400")
        self.assertEqual(fields["previous_month_10_hca"], 23.6)

    def test_other_frames_do_not_match(self):
        fmt = vf.Format(HC)
        # izar-like frame of another manufacturer, and a Hydroclima of version 0x53
        self.assertIsNone(fmt.decode(bytes.fromhex("1944304C72242421D401A2013D4013DD8B46A4999C1293E582CC"), {}))
        other_version = LONG_400[:16] + "53" + LONG_400[18:]
        self.assertIsNone(fmt.decode(bytes.fromhex(other_version), {}))

    def test_malformed_files_are_refused(self):
        def broken(**changes):
            spec = json.loads(json.dumps(HC))
            spec.update(changes)
            return spec
        cases = [
            broken(schema=2),
            broken(name="Bad-Name"),
            broken(tests=[]),
            broken(transform=[{"op": "mul", "const": 3}]),
            broken(transform=[{"op": "add", "var": "D"}, {"op": "add", "var": "A"}]),  # D not last
            broken(vars={"A": {"expr": "id0 ** 2"}}),
            broken(frames={}),
        ]
        for spec in cases:
            with self.assertRaises(vf.FormatError):
                vf.Format(spec)


class Stage(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        (self.dir / "meter-0001").write_text("name=radiator\nid=78240400\ndriver=vendor_bmeters_hydroclima_v34\n")

    def tearDown(self):
        self.tmp.cleanup()

    def stage(self, lines, status=None, formats=FORMATS):
        args = ["stage", f"--meter-dir={self.dir}", f"--formats-dir={formats}"]
        if status is not None:
            p = self.dir / "status.json"
            p.write_text(json.dumps(status))
            args.append(f"--status={p}")
        out = io.StringIO()
        with mock.patch("sys.stdin", io.StringIO("".join(x + "\n" for x in lines))), \
                mock.patch("sys.stdout", out), mock.patch("sys.stderr", io.StringIO()):
            self.assertEqual(vf.main(args), 0)
        return [json.loads(x) for x in out.getvalue().splitlines()]

    def test_configured_meter_long_then_short(self):
        rows = self.stage([SHORT_400, LONG_400, SHORT_400, "not hex", LONG_445])
        self.assertEqual(len(rows), 2)  # short before long: skipped; 445 not configured
        first, second = rows
        self.assertEqual(first["_"], "telegram")
        self.assertEqual(first["id"], "78240400")
        self.assertEqual(first["name"], "radiator")
        self.assertEqual(first["driver"], "vendor_bmeters_hydroclima_v34")
        self.assertEqual(first["allocation_hca"], 51.7)
        self.assertNotIn("previous_month_10_hca", first)
        # the short frame adds the history and keeps the long frame's values
        self.assertEqual(second["previous_month_10_hca"], 23.6)
        self.assertEqual(second["allocation_hca"], 51.7)
        self.assertIn("timestamp", second)

    def test_upstream_or_failed_format_is_not_used(self):
        for row in ({"name": HC["name"], "ok": True, "upstream_driver": "hydroclima"},
                    {"name": HC["name"], "ok": False, "upstream_driver": ""}):
            self.assertEqual(self.stage([LONG_400], status={"formats": [row]}), [])

    def test_broken_formats_dir_still_reads_to_the_end(self):
        bad = self.dir / "formats"
        bad.mkdir()
        (bad / "x.json").write_text("{not json")
        self.assertEqual(self.stage([LONG_400] * 3, formats=bad), [])


class Upstream(unittest.TestCase):
    def fake(self, stdout):
        return mock.patch("subprocess.run", return_value=subprocess.CompletedProcess([], 0, stdout, ""))

    def test_probe_with_the_values_means_handled_upstream(self):
        fmt = vf.Format(HC)
        line = json.dumps({"_": "telegram", "driver": "hydroclima", "id": "78240400",
                           "allocation_hca": 51.7, "target_hca": 93.8})
        with self.fake("noise\n" + line + "\n"):
            self.assertEqual(vf.probe_upstream(fmt, "wmbusmeters"), "hydroclima")

    def test_null_or_partial_values_are_not_enough(self):
        fmt = vf.Format(HC)
        for obj in ({"_": "telegram", "driver": "hydroclima", "allocation_hca": None},
                    {"_": "telegram", "driver": "hydroclima", "allocation_hca": 51.7}):
            with self.fake(json.dumps(obj) + "\n"):
                self.assertEqual(vf.probe_upstream(fmt, "wmbusmeters"), "")

    def test_missing_wmbusmeters(self):
        with mock.patch("subprocess.run", side_effect=FileNotFoundError):
            self.assertEqual(vf.probe_upstream(vf.Format(HC), "/nowhere"), "")

    def test_status_file(self):
        with tempfile.TemporaryDirectory() as d:
            status = os.path.join(d, "s.json")
            with self.fake(""), mock.patch("sys.stderr", io.StringIO()):
                vf.main(["upstream", f"--status={status}", f"--formats-dir={FORMATS}", "--wmbusmeters=x"])
            rows = vf.read_status(status)
            self.assertTrue(rows[HC["name"]]["ok"])
            self.assertEqual(rows[HC["name"]]["upstream_driver"], "")


class MeterRouting(unittest.TestCase):
    METERS = [
        {"id": "water", "meter_id": "03264950", "type": "hydrodigit"},
        {"id": "radiator", "meter_id": "78240400", "type": "other", "type_other": "vendor_bmeters_hydroclima_v34"},
        {"id": "nope", "meter_id": "12345678", "type": "other", "type_other": "vendor_unknown_format"},
    ]

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = Path(self.tmp.name)
        self.main = d / "etc" / "wmbusmeters.d"
        self.vendor = d / "vendor" / "meters.d"
        self.main.mkdir(parents=True)
        self.vendor.mkdir(parents=True)
        (self.vendor / "meter-0009").write_text("stale\n")
        self.options = d / "options.json"
        self.options.write_text(json.dumps({"meters": self.METERS}))
        self.status = d / "status_vendor_formats.json"

    def tearDown(self):
        self.tmp.cleanup()

    def refresh(self, upstream=""):
        self.status.write_text(json.dumps({"formats": [
            {"name": HC["name"], "ok": True, "reason": "", "upstream_driver": upstream}]}))
        out, err = io.StringIO(), io.StringIO()
        with mock.patch("sys.stdout", out), mock.patch("sys.stderr", err):
            wm.main(["refresh", f"--options={self.options}", f"--meter-dir={self.main}",
                     "--search-candidates-file=", f"--vendor-meter-dir={self.vendor}",
                     f"--vendor-status={self.status}", f"--vendor-formats-dir={FORMATS}"])
        sets = dict(ln.split("\x1f")[1:3] for ln in out.getvalue().splitlines() if ln.startswith("set\x1f"))
        return sets, err.getvalue()

    def files(self, d):
        return {p.name: p.read_text() for p in sorted(d.glob("meter-*"))}

    def test_vendor_meter_goes_to_its_own_directory(self):
        sets, err = self.refresh()
        self.assertEqual(sets["VENDOR_METERS_COUNT"], "1")
        self.assertEqual(sets["OFFICIAL_METERS_COUNT"], "2")
        main, vendor = self.files(self.main), self.files(self.vendor)
        self.assertEqual(list(vendor), ["meter-0001"])
        self.assertIn("driver=vendor_bmeters_hydroclima_v34", vendor["meter-0001"])
        self.assertEqual(len(main), 1)
        self.assertNotIn("vendor_", "".join(main.values()))
        self.assertIn("vendor_unknown_format", err)  # skipped with a warning
        self.assertEqual(vf.read_meters(str(self.vendor)), {"78240400": ("radiator", "vendor_bmeters_hydroclima_v34")})

    def test_upstream_driver_takes_over(self):
        sets, err = self.refresh(upstream="hydroclima")
        self.assertEqual(sets["VENDOR_METERS_COUNT"], "0")
        self.assertEqual(self.files(self.vendor), {})
        main = "".join(self.files(self.main).values())
        self.assertIn("id=78240400\ndriver=hydroclima\n", main)
        self.assertIn("wmbusmeters now decodes", err)


if __name__ == "__main__":
    unittest.main()
