# M-Bus slave simulator (ESP8266)

Answers `SND_NKE` and `REQ_UD2` like a wired M-Bus meter, so the polling dialogue in
`bridge-lib/14-mbus.sh` can be exercised **without a real bus**. Everything the add-on
does behind the M-Bus tab was verified against this before release.

## Hardware

An ESP8266 board with a **CH340/CP2102 bridge** (a Wemos D1 mini clone was used).
Boards with **native USB-CDC** (ESP32-S3/C3, `303a:1001`) work for the dialogue but
**cannot test parity or baud rate** — USB CDC ignores line settings, exactly like a
PTY pair does.

## Wiring it to the decoder

`wmbusmeters.conf`:

```
loglevel=verbose
device=MAIN=/dev/serial/by-id/usb-1a86_USB2.0-Ser_-if00-port0:mbus:2400
donotprobe=all
logfile=/dev/stdout
format=json
logtelegrams=true
```

`wmbusmeters.d/meter-sim`:

```
name=sim
driver=piigth:MAIN:mbus
id=p1
pollinterval=5s
```

`pollinterval` is **mandatory in the meter file**. It is not a key of
`wmbusmeters.conf` — the parser answers `No such key: pollinterval` and carries on —
and `--pollinterval` cannot be combined with `--useconfig`. Without it nothing is
ever polled, and that looks exactly like a dead meter.

Expected on `p1`: JSON with `temperature_c: 23.02` and `id: 10000284`.

## Scenarios, selected by address

| Address | Behaviour | What it exercises |
|---|---|---|
| `p1` | answers correctly | happy path, entities are created |
| `p2` | silent | `did not send a response!`, no JSON |
| `p3` | answers after 3 s | late reply — the decoder accepts it, there is no short timeout |
| `p4` | answers with non-M-Bus bytes | `no 0x68 byte found` — foreign protocol (DLMS/COSEM) |
| `p5` | answers `E5` only | indistinguishable from silence, by design |
| `p6` | two frames, different ids | two meters on one address — the decoder reports neither problem |
| `p7` | frame with a broken checksum | `expected checksum 0xNN but got 0xMM` |
| `0xFE` | answers the test broadcast | bus-liveness probe |
| others | silence | address scan |

Two more scenarios need no code: unplugging the cable mid-poll (the decoder waits and
reconnects on its own) and resetting the board, whose ROM loader emits bytes at
74880 baud — free input for the "this is not M-Bus" detection.

## Where the reply frame comes from

`RSP_USER` is taken from the upstream corpus
(`tests/test_libmbus_secondary_address.sh`, wmbusmeters v3.0.0 `ac4f295`) and is not
invented. Verified: `L=56`, `C=0x08` (RSP_UD), `CI=0x72`, checksum `0x03`. The address
and id are patched at runtime and the checksum recomputed.

The transport header carries `84 02 00 10` = **id 10000284**, which matters for the
whole design: polling primary address `p1` returns the meter's **own** identifier, and
that is what reaches the JSON and passes the `^[0-9A-Fa-f]{8}$` gate.

## The single-UART trap

The ESP8266 has one usable UART and it is the one behind the CH340. `Serial.print()`
is therefore forbidden in this sketch — the logs would go straight onto the "bus".
Diagnostics use `Serial1` (GPIO2, TX only) under `DIAG=1`; on a D1 mini that pin is
shared with the on-board LED.

## What this cannot test

Bus electrics (power budget, terminators, cable length) and the quirks of a real
converter or real meters. A simulator answers the way it was written — it confirms
that the code does what was designed, not that the design matches reality.
