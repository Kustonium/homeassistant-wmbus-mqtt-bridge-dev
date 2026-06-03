#!/usr/bin/env bash
# Regression test: primary meter value selection must prefer current totals over
# historical/helper readings regardless of JSON field order.
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
BRIDGE_SH="${ROOT_DIR}/rootfs/usr/bin/bridge.sh"
METERS_LIB="${ROOT_DIR}/rootfs/usr/bin/bridge-lib/07-meters.sh"
HELPER_SOURCE="${BRIDGE_SH}"
if [[ -f "${METERS_LIB}" ]]; then
  HELPER_SOURCE="${METERS_LIB}"
fi

command -v jq >/dev/null 2>&1 || {
  echo "FAIL: missing jq" >&2
  exit 1
}

helper_def="$(
  awk '
    /^_select_primary_meter_value\(\) \{/ { in_fn = 1 }
    in_fn { print }
    in_fn && /^}$/ { exit }
  ' "${HELPER_SOURCE}"
)"

if [[ -z "${helper_def}" ]]; then
  echo "FAIL: _select_primary_meter_value() not found in ${HELPER_SOURCE}" >&2
  exit 1
fi

eval "${helper_def}"

assert_key() {
  local label="$1"
  local expected_key="$2"
  local json_line="$3"
  local actual_key actual_value

  IFS=$'\t' read -r actual_key actual_value < <(_select_primary_meter_value "${json_line}") || true
  actual_key="${actual_key%$'\r'}"
  actual_value="${actual_value%$'\r'}"
  if [[ "${actual_key}" == "${expected_key}" && -n "${actual_value}" ]]; then
    pass "${label}: ${actual_key}=${actual_value}"
  else
    fail "${label}: expected ${expected_key}, got ${actual_key:-<empty>}=${actual_value:-<empty>}"
  fi
}

assert_key_value() {
  local label="$1"
  local expected_key="$2"
  local expected_value="$3"
  local json_line="$4"
  local actual_key actual_value

  IFS=$'\t' read -r actual_key actual_value < <(_select_primary_meter_value "${json_line}") || true
  actual_key="${actual_key%$'\r'}"
  actual_value="${actual_value%$'\r'}"
  if [[ "${actual_key}" == "${expected_key}" && "${actual_value}" == "${expected_value}" ]]; then
    pass "${label}: ${actual_key}=${actual_value}"
  else
    fail "${label}: expected ${expected_key}=${expected_value}, got ${actual_key:-<empty>}=${actual_value:-<empty>}"
  fi
}

assert_key "izar keeps current total when last_month is first" "total_m3" \
  '{"meter":"izar","last_month_total_m3":91.2,"total_m3":12.345}'
assert_key "izar keeps current total when total is first" "total_m3" \
  '{"meter":"izar","total_m3":12.345,"last_month_total_m3":91.2}'
assert_key_value "izar decoded JSON keeps current total when last_month is first" "total_m3" "430.142" \
  '{"meter":"izar","id":"215f908a","last_month_total_m3":407.603,"total_m3":430.142}'
assert_key_value "izar decoded JSON keeps current total when total is first" "total_m3" "430.142" \
  '{"meter":"izar","id":"215f908a","total_m3":430.142,"last_month_total_m3":407.603}'
assert_key "izarv2 keeps current total when last_month is first" "total_m3" \
  '{"meter":"izarv2","last_month_total_m3":77.7,"total_m3":21.509}'
assert_key "izarv2 keeps current total when total is first" "total_m3" \
  '{"meter":"izarv2","total_m3":21.509,"last_month_total_m3":77.7}'
assert_key "total_m3 wins over at_history fields" "total_m3" \
  '{"meter":"izar","at_history_total_m3":88.8,"total_m3":13.579}'

assert_key "hydrodigit keeps total_m3 over backflow" "total_m3" \
  '{"meter":"hydrodigit","backflow_m3":1291845,"total_m3":38.031}'
assert_key "qwaterv2 keeps total_m3 over target" "total_m3" \
  '{"meter":"qwaterv2","target_m3":50,"total_m3":24.016}'
assert_key "iwmtx5 keeps total_volume_m3 over previous month" "total_volume_m3" \
  '{"meter":"iwmtx5","previous_month_total_m3":41.1,"total_volume_m3":40.627}'
assert_key "evo868 keeps total_m3 over billing" "total_m3" \
  '{"meter":"evo868","billing_total_m3":99.9,"total_m3":14.051}'
assert_key "qheatv2 keeps total_kwh over previous year" "total_kwh" \
  '{"meter":"qheatv2","previous_year_total_kwh":1200,"total_kwh":456.7}'
assert_key "amiplus keeps cumulative energy over live power" "total_energy_consumption_kwh" \
  '{"meter":"amiplus","current_power_consumption_kw":0.39,"total_energy_consumption_kwh":3861.107,"total_energy_consumption_tariff_1_kwh":3861.107}'

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
