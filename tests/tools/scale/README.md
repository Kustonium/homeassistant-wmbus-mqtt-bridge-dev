# Prod-scale measurement scripts (add-on image, not run by CI)

Used to measure the bridge in the add-on image at the scale of a 5-board site
with ~210 meters on air (3 unique telegrams/s, each heard by 5 boards:
telegram + /rx + rssi per board). They were written for a scratch directory
(the `SP=` / `REPO=` lines at the top); adjust those paths before running.

- `gen.py` - seeds /config (10 official meters, 200 preview candidates) and the
  telegram stream (every telegram of a meter differs; 5 % random A-field).
- `feed.py` - publishes the stream from 5 boards (amqtt client on the host).
- `sampler.py` - CPU per window of the decode loop, the LISTEN parser and the
  RAW delegation loop (host /proc), preview one-shots per minute.
- `write_bytes_run.sh` + `attr.py` - bytes written per file (strace -f -y).
- `zero_meters_run.sh` - the zero-meter mode (`meters: []`) under s6 (/init),
  CPU per loop, then forks/bytes of the decode loop under strace.
