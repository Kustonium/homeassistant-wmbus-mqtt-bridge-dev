#!/usr/bin/env bash
# Regression test: emit_discovery_from_json must publish a Discovery config for
# every text field of a decoded telegram, disabled by default, without changing
# how numeric fields are published.
#
# Background: the field loop used to select only JSON values of type "number",
# so a driver reporting its state as current_status / frame_status (apatorna1)
# produced no Home Assistant entity for those values at all.
set -euo pipefail

PASS=0
FAIL=0

pass() { echo "PASS: $*"; PASS=$(( PASS + 1 )); }
fail() { echo "FAIL: $*" >&2; FAIL=$(( FAIL + 1 )); }

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
[[ "${SCRIPT_DIR}" == "${SCRIPT_PATH}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_DIR="${ROOT_DIR}/rootfs/usr/bin/bridge-lib"

command -v jq >/dev/null 2>&1 || {
  echo "FAIL: missing jq" >&2
  exit 1
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
CAPTURE="${WORK_DIR}/published.tsv"
: > "${CAPTURE}"

# Environment the sourced bridge-lib files read. ShellCheck cannot follow the
# dynamic source paths below, hence the explicit disable.
# shellcheck disable=SC2034
{
  DISCOVERY_ENABLED="true"
  DISCOVERY_PREFIX="homeassistant"
  DISCOVERY_RETAIN="true"
  STATE_PREFIX="wmbusmeters"
  SEARCH_MODE="false"
}

warn() { :; }
log() { :; }
normalize_meter_id() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
# Fixed stats so expire_after is deterministic: seen/avg/short/long.
status_seen_stats() { printf '%s\t%s\t%s\t%s\n' 12 900 3 10; }
mqtt_pub() { printf '%s\t%s\n' "$1" "${2//$'\n'/ }" >> "${CAPTURE}"; return 0; }

# shellcheck source=/dev/null
source "${LIB_DIR}/01-utils.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/08-discovery-helpers.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/09-discovery.sh"

# Real apatorna1 telegram shape: three numeric fields, five text fields, plus a
# "status" field that must keep its own dedicated entity pair.
TELEGRAM='{"_":"telegram","current_status":"OK","frame_status":"SUMMER_TIME","historic_age_h":304,"historic_datetime":"2026-07-31 22:08","historic_m3":1785.804,"historic_status":"MINIMUM_FLOW","id":"04913581","media":"water","meter":"apatorna1","meter_datetime":"2026-08-13 14:08","name":"Cold_Water_3581","status":"OK","timestamp":"2026-08-13T13:22:13Z","total_m3":1798.2}'

emit_discovery_from_json "${TELEGRAM}"

payload_for() {
  local field="$1"
  awk -F'\t' -v topic="homeassistant/sensor/wmbus_04913581/${field}/config" \
    '$1 == topic { print $2 }' "${CAPTURE}" | tail -n 1
}

assert_disabled_text_field() {
  local field="$1"
  local payload enabled category unit
  payload="$(payload_for "${field}")"
  if [[ -z "${payload}" ]]; then
    fail "${field}: no discovery config published"
    return
  fi
  # NB: jq's // treats a literal false as empty, so test presence explicitly.
  enabled="$(jq -r 'if has("enabled_by_default") then (.enabled_by_default|tostring) else "missing" end' <<<"${payload}" 2>/dev/null || echo parse_error)"
  category="$(jq -r '.entity_category // "missing"' <<<"${payload}" 2>/dev/null || echo parse_error)"
  unit="$(jq -r 'has("unit_of_measurement")' <<<"${payload}" 2>/dev/null || echo parse_error)"
  if [[ "${enabled}" == "false" && "${category}" == "diagnostic" && "${unit}" == "false" ]]; then
    pass "${field}: diagnostic, disabled by default, no unit"
  else
    fail "${field}: enabled_by_default=${enabled} entity_category=${category} has_unit=${unit}"
  fi
}

assert_enabled_numeric_field() {
  local field="$1"
  local expected_unit="$2"
  local payload enabled unit
  payload="$(payload_for "${field}")"
  if [[ -z "${payload}" ]]; then
    fail "${field}: no discovery config published"
    return
  fi
  enabled="$(jq -r 'has("enabled_by_default")' <<<"${payload}" 2>/dev/null || echo parse_error)"
  unit="$(jq -r '.unit_of_measurement // ""' <<<"${payload}" 2>/dev/null || echo parse_error)"
  if [[ "${enabled}" == "false" && "${unit}" == "${expected_unit}" ]]; then
    pass "${field}: still enabled, unit=${unit}"
  else
    fail "${field}: has_enabled_by_default=${enabled} unit=${unit} (expected unit ${expected_unit})"
  fi
}

for f in current_status frame_status historic_status historic_datetime meter_datetime; do
  assert_disabled_text_field "${f}"
done

assert_enabled_numeric_field total_m3 "m³"
assert_enabled_numeric_field historic_m3 "m³"
assert_enabled_numeric_field historic_age_h "h"

# The dedicated status block owns .../status/config and .../status_problem/config.
# The generic loop must not publish a second, conflicting config for "status".
status_configs="$(awk -F'\t' '$1 == "homeassistant/sensor/wmbus_04913581/status/config"' "${CAPTURE}" | wc -l | tr -d ' ')"
if [[ "${status_configs}" == "1" ]]; then
  pass "status: exactly one config published (dedicated diagnostic sensor)"
else
  fail "status: expected 1 config, got ${status_configs}"
fi

status_payload="$(payload_for status)"
if [[ "$(jq -r 'has("enabled_by_default")' <<<"${status_payload}" 2>/dev/null || echo parse_error)" == "false" ]]; then
  pass "status: dedicated sensor stays enabled by default"
else
  fail "status: dedicated sensor unexpectedly carries enabled_by_default"
fi

if grep -q -F 'homeassistant/binary_sensor/wmbus_04913581/status_problem/config' "${CAPTURE}"; then
  pass "status_problem: binary_sensor still published"
else
  fail "status_problem: binary_sensor missing"
fi

# Metadata must never become an entity.
for f in id name meter media timestamp; do
  if grep -q -F "homeassistant/sensor/wmbus_04913581/${f}/config" "${CAPTURE}"; then
    fail "${f}: metadata field must not get a discovery config"
  else
    pass "${f}: metadata field correctly skipped"
  fi
done

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
