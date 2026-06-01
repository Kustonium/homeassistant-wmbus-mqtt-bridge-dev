#!/usr/bin/env bash
# Optional integration test: decode real IZAR HEX fixtures with wmbusmeters,
# then verify the bridge primary value selector keeps the current total.
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
[[ "${SCRIPT_DIR}" == "${SCRIPT_PATH}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BRIDGE_SH="${ROOT_DIR}/rootfs/usr/bin/bridge.sh"
FIXTURE_DIR="${ROOT_DIR}/tests/fixtures/izar"
EXPECTED_TSV="${FIXTURE_DIR}/expected.tsv"

if ! command -v wmbusmeters >/dev/null 2>&1; then
  echo "SKIP: missing wmbusmeters"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: missing jq"
  exit 0
fi

helper_def="$(
  awk '
    /^_select_primary_meter_value\(\) \{/ { in_fn = 1 }
    in_fn { print }
    in_fn && /^}$/ { exit }
  ' "${BRIDGE_SH}"
)"

if [[ -z "${helper_def}" ]]; then
  echo "FAIL: _select_primary_meter_value() not found in bridge.sh" >&2
  exit 1
fi

eval "${helper_def}"

PASS=0
FAIL=0

pass() { echo "PASS: $*"; PASS=$(( PASS + 1 )); }
fail() { echo "FAIL: $*" >&2; FAIL=$(( FAIL + 1 )); }

while IFS=$'\t' read -r meter_id driver expected_key expected_value; do
  [[ -n "${meter_id}" ]] || continue
  hex_file="${FIXTURE_DIR}/${meter_id}.hex"
  if [[ ! -f "${hex_file}" ]]; then
    fail "${meter_id}: missing fixture ${hex_file}"
    continue
  fi

  hex="$(tr -d '\r\n[:space:]' < "${hex_file}")"
  decoded_json="$(
    printf '%s\n' "${hex}" \
      | wmbusmeters --silent --format=json stdin:hex "fixture_${meter_id}" "${driver}" "${meter_id}" NOKEY \
      | jq -c 'select(type=="object")' \
      | head -n 1
  )"

  if [[ -z "${decoded_json}" ]]; then
    fail "${meter_id}: wmbusmeters produced no JSON"
    continue
  fi

  IFS=$'\t' read -r actual_key actual_value < <(_select_primary_meter_value "${decoded_json}") || true
  actual_key="${actual_key%$'\r'}"
  actual_value="${actual_value%$'\r'}"
  if [[ "${actual_key}" == "${expected_key}" && "${actual_value}" == "${expected_value}" ]]; then
    pass "${meter_id}: ${actual_key}=${actual_value}"
  else
    fail "${meter_id}: expected ${expected_key}=${expected_value}, got ${actual_key:-<empty>}=${actual_value:-<empty>}; json=${decoded_json}"
  fi
done < "${EXPECTED_TSV}"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
