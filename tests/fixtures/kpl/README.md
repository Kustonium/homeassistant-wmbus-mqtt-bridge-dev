# `kpl/12345678` — synthetic, guards the Tauron/KPL local patch

This telegram is **constructed, not captured**. It exists so that CI notices if
`patches/0001-kpl-decrypt-check-bytes.patch` ever stops working — the patch
applies at image build time, and "it still applies" is not the same as "it still
does anything".

Built to be exactly what the patch keys on:

| field | value |
|---|---|
| manufacturer | `KPL` (`0x2E0C`) |
| id / version / type | `12345678` / `01` / `02` |
| TPL security mode | 5 (`AES_CBC_IV`), 1 encrypted block |
| IV | `mfct(2) + A(6) + acc x8`, per `decrypt_TPL_AES_CBC_IV()` |
| key | `000102…0E0F` — invented here, guards nothing real |
| plaintext | `60 9b` + `0C 13 78563412` (volume) + `2f` padding |

Measured behaviour, both directions:

- **without** the patch: `609b decrypt check bytes (ERROR should be 2f2f)` and
  `failed decryption. Wrong key?` — while the very same log line prints the
  correctly decrypted plaintext. No JSON, so this fixture fails.
- **with** the patch: check bytes read `2f2f`, the telegram parses, JSON is emitted
  and compared against the golden file.

The golden itself is deliberately thin (`id`, `media`, `meter`): `amiplus` is an
electricity driver and does not map the volume record this frame carries. That is
fine for what this fixture is for — it gates on *whether a telegram survives
decryption at all*, and without the patch there is no JSON to compare.

**What this does NOT prove.** That a real Tauron meter emits `60 9b`. That claim
comes from a single user report (forum.arturhome.pl, "Licznik S34U28 od
Taurona") and no raw telegram was ever available here. A synthetic frame can
only demonstrate that our code does what we think it does — it cannot testify
about somebody else's hardware. If you have this meter, a captured telegram
would replace this file with something that actually settles it.

The driver is `amiplus` because that is what a user with this meter is told to
configure; detection cannot find it, since no upstream driver claims `KPL`.
