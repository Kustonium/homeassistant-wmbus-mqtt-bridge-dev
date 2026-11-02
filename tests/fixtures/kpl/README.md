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

The golden itself is deliberately thin (`id`, `media`, the driver name): neither
`amiplus` nor `sanxing` maps the volume record this frame carries. That is
fine for what this fixture is for — it gates on *whether a telegram survives
decryption at all*, and without the patch there is no JSON to compare.

**What this does NOT prove.** That a real Tauron meter emits `60 9b`. That claim
comes from a single user report (forum.arturhome.pl, "Licznik S34U28 od
Taurona") and no raw telegram was ever available here. A synthetic frame can
only demonstrate that our code does what we think it does — it cannot testify
about somebody else's hardware. If you have this meter, a captured telegram
would replace this file with something that actually settles it.

Up to wmbusmeters 3.0.0 the driver here was `amiplus`, because that is what a
user with this meter is told to configure; detection could not find it, since no
upstream driver claimed `KPL`.

**Since wmbusmeters 3.1.x** upstream handles these meters itself: the `sanxing`
driver claims `KPL` (so `auto` picks it) and accepts the `60 9b` check bytes, and
the local patch retires itself (`apply-local-patches.sh` prints "upstream now
handles KPL itself"). `amiplus` without the patch fails this frame again
("decrypted content failed check ... Permanently ignoring"), so the fixture now
runs with `sanxing` and still gates on the same thing: the telegram survives
decryption. Measured on 3.1.1 (`80ea8218`): `amiplus` no JSON, `sanxing` and
`auto` the golden below. Whether a real Tauron meter's readings come out the same
under `sanxing` as they did under the patched `amiplus` is not settled by this
synthetic frame — that needs a captured telegram.
