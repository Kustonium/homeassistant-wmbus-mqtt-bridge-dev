#!/usr/bin/env bash
# Regression test for issue #157: _raw_source must hand every RAW line on as
# soon as the publisher's raw port sends it. With `exec cat <&3` a line waited
# for the next one (cat copies with splice, and a splice from a TCP socket
# returns only when more data arrives), so a lone meter's telegrams were
# decoded in pairs. Runs the real function against a local server that sends a
# line every 0.6 s and checks each one arrives within 0.3 s.
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
[[ "${SCRIPT_DIR}" == "${SCRIPT_PATH}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PIPELINE_SH="${ROOT_DIR}/rootfs/usr/bin/bridge-lib/12-pipeline.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

fn="$(sed -n '/^_raw_source() {/,/^}/p' "${PIPELINE_SH}")"
[[ -n "${fn}" ]] || fail "_raw_source not found in 12-pipeline.sh"
eval "${fn}"

TMP="$(mktemp -d)"
SERVER_PID=""
trap 'rm -rf "${TMP}"; [[ -n "${SERVER_PID}" ]] && kill "${SERVER_PID}" 2>/dev/null || true' EXIT

python3 -u - "${TMP}/port" "${TMP}/sent" <<'PY' &
import socket, sys, time
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(1)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
c, _ = s.accept()
with open(sys.argv[2], "w") as log:
    for i in range(4):
        line = "AA%02d" % i
        log.write("%s %.3f\n" % (line, time.time()))
        log.flush()
        c.sendall(line.encode() + b"\n")
        time.sleep(0.6)
time.sleep(0.5)
c.close()
PY

for _ in $(seq 50); do [[ -s "${TMP}/port" ]] && break; sleep 0.1; done
[[ -s "${TMP}/port" ]] || fail "test server did not start"
# shellcheck disable=SC2034  # read by the eval-ed _raw_source
MQTT_PUB_RAW_PORT="$(cat "${TMP}/port")"

( _raw_source ) | python3 -u -c '
import sys, time
for line in sys.stdin:
    print("%s %.3f" % (line.strip(), time.time()), flush=True)
' > "${TMP}/recv"

python3 - "${TMP}/sent" "${TMP}/recv" <<'PY' || fail "a RAW line was held back (see above)"
import sys
sent = dict(l.split() for l in open(sys.argv[1]))
recv = dict(l.split() for l in open(sys.argv[2]))
bad = []
for line, t in sent.items():
    if line not in recv:
        bad.append(f"{line} never arrived")
    elif float(recv[line]) - float(t) > 0.3:
        bad.append(f"{line} arrived {float(recv[line]) - float(t):.2f} s late")
for b in bad:
    print(b)
sys.exit(1 if bad else 0)
PY
echo "OK: _raw_source hands every RAW line on at once"
