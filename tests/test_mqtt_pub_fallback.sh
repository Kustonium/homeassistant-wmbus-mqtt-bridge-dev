#!/usr/bin/env bash
# Regression test: mqtt_pub must never lose its caller to the persistent
# publisher, and must fall back to mosquitto_pub when the publisher is gone.
#
#   - no publisher listening: the message goes out through mosquitto_pub;
#   - a publisher that accepts and closes at once (dies mid-message): the
#     write fails with EPIPE/ECONNRESET. Unguarded, bash would die of SIGPIPE
#     here - and the caller is the decode loop or the heartbeat ticker. The
#     shell has to survive and the message has to fall back;
#   - persistent publishing disabled: mosquitto_pub, publisher never asked.
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
[[ "${SCRIPT_DIR}" == "${SCRIPT_PATH}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd)"
LIB="${SCRIPT_DIR}/../rootfs/usr/bin/bridge-lib/12-pipeline.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || fail "missing python3"

WORK="$(mktemp -d)"
SERVER_PID=""
trap '[[ -z "${SERVER_PID}" ]] || kill "${SERVER_PID}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT

log() { :; }
warn() { :; }
# shellcheck source=/dev/null
source "${LIB}"

# mosquitto_pub stand-in: records what it was asked to send.
MOSQUITTO_PUB_BIN="${WORK}/mosquitto_pub"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/fallback.log"\n' "${WORK}" > "${MOSQUITTO_PUB_BIN}"
chmod +x "${MOSQUITTO_PUB_BIN}"
# shellcheck disable=SC2034  # read by mqtt_pub
PUB_ARGS=( -h broker -p 1883 )
fallbacks() { [[ -f "${WORK}/fallback.log" ]] && wc -l < "${WORK}/fallback.log" || echo 0; }

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

# 1. Nothing listens on the port.
MQTT_PUB_PORT="$(free_port)"
mqtt_pub "a/b" '{"x":1}' "true"
[[ "$(fallbacks)" -eq 1 ]] || fail "closed port: expected 1 mosquitto_pub, got $(fallbacks)"
grep -q -- '-h broker -p 1883 -t a/b -r -m {"x":1}' "${WORK}/fallback.log" \
  || fail "closed port: mosquitto_pub got the wrong arguments: $(cat "${WORK}/fallback.log")"

# 2. A publisher that accepts and resets every connection straight away.
python3 - "${WORK}/rst.port" <<'EOF' &
import socket, struct, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(64)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
while True:
    c, _ = s.accept()
    c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    c.close()
EOF
SERVER_PID=$!
for _ in $(seq 50); do [[ -s "${WORK}/rst.port" ]] && break; sleep 0.1; done
MQTT_PUB_PORT="$(< "${WORK}/rst.port")"
# Larger than the socket buffers, so every write runs into the reset. (Too
# large for the stand-in's argv, so its exec fails - that does not matter.)
big="$(head -c 3000000 /dev/zero | tr '\0' 'x')"
rc=0
(
  for _ in 1 2 3 4 5; do
    mqtt_pub "big/state" "${big}" "false" 2>/dev/null
  done
  echo alive > "${WORK}/alive"
) || rc=$?
[[ "${rc}" -eq 0 && -s "${WORK}/alive" ]] \
  || fail "the publishing shell died (rc=${rc}; 141 = SIGPIPE) when the publisher went away"
# A small message: the reset either makes the write fail (fallback) or the
# kernel accepted it first (lost, like a failed mosquitto_pub). Never both.
before="$(fallbacks)"
mqtt_pub "small/state" "1" "false"
(( $(fallbacks) - before <= 1 )) || fail "one message was handed to mosquitto_pub twice"

# 3. Disabled: start_mqtt_publisher leaves MQTT_PUB_PORT empty.
MQTT_PUB_PORT=""
MQTT_PERSISTENT_PUBLISHER=false start_mqtt_publisher
[[ -z "${MQTT_PUB_PORT}" ]] || fail "disabled publisher still set MQTT_PUB_PORT"
[[ -z "${MQTT_PUBLISHER_PID}" ]] || fail "disabled publisher was started"

echo "PASS: mqtt_pub falls back to mosquitto_pub and survives a publisher that goes away"
