#!/usr/bin/env python3
"""custom_drivers.py: the checks that keep a bad external driver away from decoding.

A fake wmbusmeters reproduces what the real one (3.1.1) did on 2026-11-07:
rc 5 for a rejected file, a crash for an empty one or a bad field, and a
detect block that silently removes a built-in driver from --listdrivers.
Set WMBUS_REAL_BIN to also run the end-to-end case against a real binary.
"""

import json
import os
import stat
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "rootfs" / "usr" / "bin"))

import custom_drivers as cd  # noqa: E402

FAKE = textwrap.dedent("""\
    #!/usr/bin/env python3
    import os, re, sys
    BUILTIN = ["auto", "izar", "hydrodigit", "kamwater"]
    d = None
    for a in sys.argv[1:]:
        if a.startswith("--driversdir="):
            d = a.split("=", 1)[1]
    names = list(BUILTIN)
    if d:
        for f in sorted(os.listdir(d)):
            t = open(os.path.join(d, f), encoding="utf-8", errors="replace").read()
            if "CRASH" in t:
                os.kill(os.getpid(), 11)
            if "BAD" in t or not t.strip():
                sys.exit(5)
            m = re.search(r"^\\s*name\\s*=\\s*(\\w+)", t, re.M)
            for r in re.findall(r"REMOVES=(\\w+)", t):
                if r in names:
                    names.remove(r)
            if m:
                names.append(m.group(1))
    for n in names:
        print(n + "  WaterMeter (builtin)")
""")


def driver(name, extra=""):
    return f"driver {{\n    name = {name}\n    meter_type = WaterMeter\n    {extra}\n}}\n"


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        fake = self.dir / "wmbusmeters"
        fake.write_text(FAKE, encoding="utf-8")
        fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
        self.env = {"WMBUSMETERS_BIN": str(fake),
                    "CUSTOM_DRIVERS_DIR": str(self.dir / "plain"),
                    "CUSTOM_DRIVERS_NDA_DIR": str(self.dir / "nda")}
        self.old = {k: os.environ.get(k) for k in self.env}
        os.environ.update(self.env)
        cd.DRIVERS_DIR = self.env["CUSTOM_DRIVERS_DIR"]
        cd.DRIVERS_NDA_DIR = self.env["CUSTOM_DRIVERS_NDA_DIR"]
        (self.dir / "plain").mkdir()
        (self.dir / "nda").mkdir()

    def tearDown(self):
        for k, v in self.old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.tmp.cleanup()

    def put(self, sub, name, text):
        p = self.dir / sub / f"{name}.xmq"
        p.write_text(text, encoding="utf-8")
        return str(p)

    def one(self, name, text, sub="nda"):
        return cd.check_files([self.put(sub, name, text)])[0]


class StaticChecks(Base):
    def test_empty_binary_and_not_a_driver_are_refused_before_any_process(self):
        self.assertEqual(cd.static_check(b"")[1], "empty")
        self.assertEqual(cd.static_check(b"\x00\x01driver {")[1], "not_text")
        self.assertEqual(cd.static_check(b"\xff\xfe\xfd")[1], "not_text")
        self.assertEqual(cd.static_check(b"hello")[1], "not_a_driver")
        self.assertEqual(cd.static_check(b"x" * (cd.MAX_BYTES + 1))[1], "too_large")

    def test_name_must_carry_the_prefix_and_be_plain(self):
        self.assertEqual(cd.static_check(driver("kamwater").encode())[1], "name_without_prefix")
        self.assertEqual(cd.static_check(driver("external_Abc").encode())[1], "bad_name")
        self.assertEqual(cd.static_check(driver("external_abc").encode()), ("external_abc", ""))


class FileChecks(Base):
    def test_valid_file_is_accepted(self):
        v = self.one("external_good", driver("external_good"))
        self.assertTrue(v["ok"], v)
        self.assertEqual(v["replaces"], [])

    def test_rejected_and_crashing_files_are_refused_with_the_reason(self):
        self.assertEqual(self.one("external_bad", driver("external_bad", "BAD"))["reason"], "rejected")
        self.assertEqual(self.one("external_boom", driver("external_boom", "CRASH"))["reason"], "crashed")

    def test_file_named_differently_from_its_driver_is_refused(self):
        p = self.put("nda", "external_one", driver("external_two"))
        self.assertEqual(cd.check_files([p])[0]["reason"], "file_name_mismatch")

    def test_removing_a_builtin_is_accepted_and_reported(self):
        v = self.one("external_hydro", driver("external_hydro", "REMOVES=hydrodigit"))
        self.assertTrue(v["ok"], v)
        self.assertEqual(v["replaces"], ["hydrodigit"])

    def test_external_file_cannot_remove_an_earlier_external_one(self):
        a = self.put("nda", "external_a", driver("external_a"))
        b = self.put("nda", "external_b", driver("external_b", "REMOVES=external_a"))
        va, vb = cd.check_files([a, b])
        self.assertTrue(va["ok"])
        self.assertFalse(vb["ok"])
        self.assertEqual(vb["reason"], "conflict")
        self.assertEqual(vb["conflicts"], ["external_a"])

    def test_same_name_twice_keeps_the_first(self):
        a = self.put("nda", "external_x", driver("external_x"))
        b = self.put("plain", "external_x", driver("external_x"))
        va, vb = cd.check_files([a, b])
        self.assertTrue(va["ok"])
        self.assertEqual(vb["reason"], "duplicate_name")

    def test_missing_wmbusmeters_refuses_everything(self):
        os.environ["WMBUSMETERS_BIN"] = str(self.dir / "nothing-here")
        v = self.one("external_good", driver("external_good"))
        self.assertFalse(v["ok"])
        self.assertEqual(v["reason"], "wmbusmeters_unavailable")


class Install(Base):
    def test_only_accepted_files_reach_the_instance_and_status_is_written(self):
        self.put("nda", "external_good", driver("external_good"))
        self.put("plain", "external_bad", driver("external_bad", "BAD"))
        dest = self.dir / "inst"
        dest.mkdir()
        (dest / "external_stale.xmq").write_text("old", encoding="utf-8")
        status = cd.install(str(dest), str(self.dir / "status.json"))
        self.assertEqual(sorted(os.listdir(dest)), ["external_good.xmq"])
        on_disk = json.loads((self.dir / "status.json").read_text(encoding="utf-8"))
        self.assertEqual(on_disk, status)
        by = {v["name"]: v for v in status["drivers"]}
        self.assertTrue(by["external_good"]["ok"] and by["external_good"]["nda"])
        self.assertFalse(by["external_bad"]["ok"] or by["external_bad"]["nda"])

    def test_disabled_option_empties_the_instance(self):
        self.put("nda", "external_good", driver("external_good"))
        dest = self.dir / "inst"
        dest.mkdir()
        (dest / "external_good.xmq").write_text(driver("external_good"), encoding="utf-8")
        status = cd.install(str(dest), str(self.dir / "status.json"), enabled=False)
        self.assertEqual(os.listdir(dest), [])
        self.assertFalse(status["enabled"])


@unittest.skipUnless(os.environ.get("WMBUS_REAL_BIN"), "WMBUS_REAL_BIN not set")
class RealWmbusmeters(Base):
    """Against wmbusmeters itself: crash, rejection and removal of a built-in."""

    def setUp(self):
        super().setUp()
        os.environ["WMBUSMETERS_BIN"] = os.environ["WMBUS_REAL_BIN"]

    def test_real_binary(self):
        self.assertEqual(self.one("external_e", "")["reason"], "empty")
        bad = "driver {\n name = external_q\n meter_type = WaterMeter\n default_fields = name,id\n" \
              " fields { field { name = a\n quantity = Banany\n } }\n}\n"
        self.assertEqual(self.one("external_q", bad)["reason"], "crashed")
        src = os.environ.get("WMBUS_REAL_SRC")
        if src:
            hydro = Path(src, "drivers", "src", "hydrodigit.xmq").read_text(encoding="utf-8")
            text = hydro.replace("name           = hydrodigit", "name           = external_hydro")
            v = self.one("external_hydro", text)
            self.assertTrue(v["ok"], v)
            self.assertIn("hydrodigit", v["replaces"])


if __name__ == "__main__":
    unittest.main()
