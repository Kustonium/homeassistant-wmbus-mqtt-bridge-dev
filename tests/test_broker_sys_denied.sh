#!/usr/bin/env bash
# Regression test: a broker that refuses $SYS is asked again after an hour,
# not every 2 minutes.
#
# EMQX's default ACL gives $SYS only to localhost clients. mosquitto_sub then
# prints "All subscription requests were denied" and exits at once, and the
# subscriber's reconnect pause retried it every 2 min - a broker connection and
# an authorization warning in the broker's log each time. This runs the real
# subscriber block of 13-esp.sh with a mosquitto_sub that refuses, and one that
# answers like Mosquitto, and checks what is recorded and how long it waits.
# The grep/sed patterns below match literal "$SYS" and "${...}" text.
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
[[ "${SCRIPT_DIR}" == "${SCRIPT_PATH}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd)"
LIB="${SCRIPT_DIR}/../rootfs/usr/bin/bridge-lib/13-esp.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# The block from its comment to the line that records the subscriber's PID.
block="$(sed -n '/^# Background subscriber for broker identity (\$SYS)/,/^ESP_SUBSCRIBER_PIDS=/p' "${LIB}")"
[[ "${block}" == *'mosquitto_sub'* && "${block}" == *'denied'* ]] || fail "broker identity subscriber not found in 13-esp.sh"
block="${block//\/usr\/bin\/mosquitto_sub/mosquitto_sub}"

run_case() {  # $1 = name, $2 = body of the fake mosquitto_sub
  local dir="${TMP}/$1"
  mkdir -p "${dir}"
  {
    echo 'set -uo pipefail'
    echo "STATUS_BROKER_INFO_FILE='${dir}/status_broker_info.txt'"
    echo 'STDBUF_BIN=""; SUB_ARGS=(); ESP_SUBSCRIBER_PIDS=""'
    echo 'epoch_now() { echo 1000; }'
    echo "mosquitto_sub() { $2; }"
    # The first wait ends the subscriber: which one it chose is the result.
    echo "sleep() { echo \"sleep \$1\" >> '${dir}/waits'; exit 0; }"
    echo "_sub_reconnect_sleep() { echo reconnect >> '${dir}/waits'; exit 0; }"
    printf '%s\n' "${block}"
    echo 'wait'
  } > "${dir}/run.sh"
  timeout 10 bash "${dir}/run.sh" || fail "$1: the subscriber did not end"
}

run_case denied 'echo "All subscription requests were denied." >&2; return 1'
[[ "$(cat "${TMP}/denied/waits")" == "sleep 3600" ]] \
  || fail "refused \$SYS: expected one wait of 3600 s, got '$(tr '\n' ' ' < "${TMP}/denied/waits")'"
[[ "$(cat "${TMP}/denied/status_broker_info.txt")" == $'\t\t\tdenied' ]] \
  || fail "refused \$SYS: the refusal is not recorded for the WebUI"

run_case mosquitto 'printf "%s\t%s\n" "\$SYS/broker/version" "mosquitto version 2.0.18"; return 0'
[[ "$(cat "${TMP}/mosquitto/waits")" == "reconnect" ]] \
  || fail "answering broker: expected the normal reconnect pause, got '$(tr '\n' ' ' < "${TMP}/mosquitto/waits")'"
[[ "$(cat "${TMP}/mosquitto/status_broker_info.txt")" == $'Mosquitto\t2.0.18\t' ]] \
  || fail "answering broker: brand and version not recorded"

echo "PASS: a broker refusing \$SYS is recorded and asked again after 3600 s; an answering one as before"
