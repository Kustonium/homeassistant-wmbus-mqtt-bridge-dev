#!/usr/bin/env bash
# Regression test: _wmbusmeters_log_stage (bridge-lib/12-pipeline.sh) is the
# only thing between wmbusmeters' addtelegramhex output - the decrypted frame -
# and MQTT, Discovery and the recorder. The log copy keeps "hex", the line passed
# on must not have it: whatever the field's position, with a byte that is not
# valid UTF-8 in the line (the image runs LANG=C.UTF-8, where such a byte made the
# patterns miss), and when the log cannot be written. Lines without "hex" pass
# unchanged. bridge.sh enables addtelegramhex only together with the RAM log.
set -euo pipefail

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$(( PASS + 1 )); }
fail() { echo "FAIL: $*" >&2; FAIL=$(( FAIL + 1 )); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

stage() {  # stage <log dir or empty> < input > output
  LANG=C.UTF-8 LC_ALL=C.UTF-8 WEBUI_LOG_DIR="$1" bash -c '
    # shellcheck disable=SC1090
    source "$0"
    _wmbusmeters_log_stage' "${ROOT_DIR}/rootfs/usr/bin/bridge-lib/12-pipeline.sh"
}

BAD=$'\xff'
{
  printf '%s\n' '{"_":"telegram","hex":"2E44AB","id":"1","total_m3":1}'
  printf '%s\n' '{"_":"telegram","id":"2","hex":"2e44ab","total_m3":1,"timestamp":"t"}'
  printf '%s\n' '{"_":"telegram","id":"3","total_m3":1,"hex":"2E44AB"}'
  printf '%s\n' "{\"_\":\"telegram\",\"id\":\"4\",\"text\":\"a${BAD}b\",\"hex\":\"2E44AB\",\"total_m3\":1}"
  printf '%s\n' '{"_":"telegram","id":"5","total_m3":1}'
  printf '%s\n' 'Started config hextty on stdin listening on any'
} > "${WORK}/in"

mkdir -p "${WORK}/log"
stage "${WORK}/log" < "${WORK}/in" > "${WORK}/out"

if grep -q '"hex"' "${WORK}/out"; then
  fail "hex passed on: $(grep '"hex"' "${WORK}/out" | head -n 1)"
else
  pass "hex removed from every line passed on (first, middle, last field, invalid UTF-8 byte)"
fi
[[ "$(wc -l < "${WORK}/out")" -eq 6 ]] && pass "every line passed on" || fail "lines passed on: $(wc -l < "${WORK}/out")"
grep -qx '{"_":"telegram","id":"1","total_m3":1}' "${WORK}/out" \
  && grep -qx '{"_":"telegram","id":"3","total_m3":1}' "${WORK}/out" \
  && grep -qx '{"_":"telegram","id":"5","total_m3":1}' "${WORK}/out" \
  && grep -qx 'Started config hextty on stdin listening on any' "${WORK}/out" \
  && pass "JSON stays valid around the removed field, other lines unchanged" \
  || fail "lines changed: $(cat "${WORK}/out")"
[[ "$(grep -c '"hex"' "${WORK}/log/wmbusmeters.log")" -eq 4 ]] \
  && pass "the log copy keeps hex" || fail "log copy: $(cat "${WORK}/log/wmbusmeters.log")"

# The log cannot be written: the field is still removed.
mkdir -p "${WORK}/ro" && chmod 500 "${WORK}/ro"
if [[ -w "${WORK}/ro" ]]; then
  echo "SKIP: running as root, cannot make the log unwritable"
else
  stage "${WORK}/ro" < "${WORK}/in" > "${WORK}/out_ro"
  if grep -q '"hex"' "${WORK}/out_ro"; then fail "hex passed on with an unwritable log"
  else pass "hex removed when the log cannot be written"; fi
fi

# bridge.sh: addtelegramhex only together with the RAM log.
grep -A2 'if \[\[ -n "\${WEBUI_LOG_DIR}" \]\]; then' "${ROOT_DIR}/rootfs/usr/bin/bridge.sh" \
  | grep -q 'addtelegramhex=true' \
  && pass "bridge.sh enables addtelegramhex only with WEBUI_LOG_DIR" \
  || fail "bridge.sh: addtelegramhex not tied to WEBUI_LOG_DIR"

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
