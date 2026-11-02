# `sanxing/real/11223344` — Tauron Sanxing S34U28, real records

Taken verbatim from the test of upstream's `sanxing` driver
(`drivers/src/sanxing.xmq` at wmbusmeters 3.1.1, `80ea8218`). Upstream's note:
real DV records from the captures in wmbusmeters/wmbusmeters#2042, re-encrypted
under a fabricated key with the id changed to 11223344. The key in
`golden.tsv` is that fabricated, public test key.

Unlike `kpl/12345678` (constructed here, only proves a telegram survives
decryption) this one carries what a real Tauron meter reports, so it pins the
fields and values users see.

Measured on the same frame:

| wmbusmeters | `amiplus` | `sanxing` / `auto` |
|---|---|---|
| 3.0.0 + local patch 0001 (add-on up to 1.6.8) | all values | no such driver / empty |
| 3.1.1 | no JSON | the golden: same fields and values as `amiplus` before, plus `absolute_max_power_consumption_kw` and `fabrication_no` |

Entities are keyed on the meter id and the field name, not the driver, so a
meter moved from `amiplus` to `sanxing` keeps its entities and history.

The frame sits one directory deeper (`sanxing/real/`) on purpose: the ledger
tests (`test_ledger_listen.sh`, `test_ledger_zero.sh`, `test_ledger_tracker.sh`,
`test_bridge_ledger.py`) draw their corpus from every `fixtures/*/*.hex`, and a new
frame there would reshuffle their recorded outputs. `golden.tsv` takes any depth.
