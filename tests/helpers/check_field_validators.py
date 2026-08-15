#!/usr/bin/env python3
"""Check how webui.py treats field entries the user left unfinished.

Called from tests/test_calculated_fields.sh, which owns the pass/fail counting;
this prints one "verdict<TAB>label<TAB>detail" line per case.

The behaviour under test exists because of the template chips in the meter
modals: clicking four of them and filling two in is the normal way to use them,
so an entry with no value is a leftover template, not an error. Rejecting the
save over it would also throw away the driver and key edited in the same modal.
A formula is the opposite case - an empty one is a typo.
"""
import pathlib
import sys

REPO = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(REPO / "rootfs" / "usr" / "bin"))

import webui  # noqa: E402

CASES = [
    ("every template left empty",
     webui._clean_static_fields("location=; apartment=; floor="), (True, "")),
    ("some filled, the rest dropped",
     webui._clean_static_fields("location=kuchnia; apartment=; floor=1"),
     (True, "location=kuchnia; floor=1")),
    ("a bad name is still refused",
     webui._clean_static_fields("Bad Name="), (False, "")),
    ("an empty formula is still refused",
     webui._clean_calculated_fields("difftemp_c="), (False, "")),
]

for label, got, want in CASES:
    ok = (got[0], got[1]) == want
    print(f"{'OK' if ok else 'BAD'}\t{label}\t{got}")
