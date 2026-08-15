#!/usr/bin/env bash
# Regression test: the user's calculate_ lines must survive into the generated
# meter file.
#
# The arithmetic is the decoder's, not ours: wmbusmeters accepts
# calculate_<name>=<formula> in a meter config file (src/config.cc, the branch
# whose error message reads "in meter config file") and publishes the result as
# an ordinary JSON field. refresh_meter_files() deletes and rewrites every
# meter-* file on start and on every soft reload, so before this the user's line
# was wiped within seconds of being written by hand - the option existed
# upstream and was unreachable from here.
#
# What is checked: the lines are written, malformed entries are dropped with a
# warning instead of poisoning the file, and no warning text can end up inside
# the file itself.
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

command -v jq >/dev/null 2>&1 || { echo "FAIL: missing jq" >&2; exit 1; }

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

WARN_LOG="${WORK_DIR}/warnings.txt"
: > "${WARN_LOG}"
warn() { printf '%s\n' "$*" >> "${WARN_LOG}"; }
log() { :; }

# shellcheck source=/dev/null
source "${LIB_DIR}/07-meters.sh"

lines_for() { build_calculated_field_lines "$1" "03534159"; }

OUT="$(lines_for 'difftemp_c=flow_temperature_c-return_temperature_c')"
if [[ "${OUT}" == "calculate_difftemp_c=flow_temperature_c-return_temperature_c" ]]; then
  pass "single formula becomes one calculate_ line"
else
  fail "single formula produced: ${OUT}"
fi

# A formula contains spaces and commas, which is why entries are split on ';'
# rather than on the separators exclude_fields uses.
OUT="$(lines_for 'sumtemp_c=flow_temperature_c + return_temperature_c; half_m3=total_m3 / 2')"
if [[ "$(printf '%s' "${OUT}" | wc -l | tr -d ' ')" == "1" \
      && "${OUT}" == *"calculate_sumtemp_c=flow_temperature_c + return_temperature_c"* \
      && "${OUT}" == *"calculate_half_m3=total_m3 / 2"* ]]; then
  pass "two formulas with spaces survive as two lines"
else
  fail "two formulas produced: ${OUT}"
fi

: > "${WARN_LOG}"
OUT="$(lines_for 'good_c=a_c+b_c; NoSuchName=1; missing_equals; empty_c=')"
if [[ "${OUT}" == "calculate_good_c=a_c+b_c" ]]; then
  pass "malformed entries are dropped, the valid one is kept"
else
  fail "mixed input produced: ${OUT}"
fi
if [[ "$(wc -l < "${WARN_LOG}" | tr -d ' ')" == "3" ]]; then
  pass "each dropped entry is reported once"
else
  fail "expected 3 warnings, got: $(cat "${WARN_LOG}")"
fi
# The generator prints only config lines; warnings must not reach stdout, or
# the caller's redirect would put them inside the meter file.
if grep -q "skipped" <<<"${OUT}"; then
  fail "warning text leaked into the generated lines: ${OUT}"
else
  pass "warnings stay out of the generated lines"
fi

# An id with hex letters must be reported verbatim in the warning, since that is
# what the user pasted into the configuration.
: > "${WARN_LOG}"
build_calculated_field_lines 'oops' '2156B4C2' >/dev/null
if grep -q "2156B4C2" "${WARN_LOG}"; then
  pass "warning names the meter it belongs to"
else
  fail "warning without meter id: $(cat "${WARN_LOG}")"
fi

# Empty and absent input produce nothing at all.
if [[ -z "$(lines_for '')" && -z "$(lines_for '   ;  ; ')" ]]; then
  pass "empty configuration writes no lines"
else
  fail "empty configuration produced output"
fi

# A newline inside an entry would let one field inject an unrelated key (say a
# second driver=) into the generated file.
: > "${WARN_LOG}"
OUT="$(lines_for "$(printf 'evil_c=1\ndriver=notmine')")"
if [[ "${OUT}" != *"driver=notmine"* ]]; then
  pass "an entry cannot inject a second key into the file"
else
  fail "newline injection reached the file: ${OUT}"
fi

# --- and now through refresh_meter_files, which is where it used to be lost ---
# The helper above could be perfect and the feature still broken: the bug was
# never in formatting a line, it was that the regenerated file contained only
# name/id/key/driver.
METER_DIR="${WORK_DIR}/wmbusmeters.d"
OPTIONS_JSON="${WORK_DIR}/options.json"
mkdir -p "${METER_DIR}"
# shellcheck disable=SC2034
{
  SEARCH_MODE="false"
  SEARCH_EXPECTED_VALUE_M3="0"
  STATUS_OFFICIAL_METERS_COUNT_FILE="${WORK_DIR}/official_meters_count"
  declare -A METER_EXCLUDE_FIELDS=()
}
write_search_status() { :; }
normalize_meter_id() { echo "$1" | tr '[:lower:]' '[:upper:]'; }

cat > "${OPTIONS_JSON}" <<'JSON'
{"meters": [
  {"id": "Heat", "meter_id": "03534159", "type": "kamheat", "key": "",
   "calculated_fields": "difftemp_c=flow_temperature_c - return_temperature_c; half_m3=total_m3 / 2"},
  {"id": "Water", "meter_id": "21031894", "type": "evo868", "key": ""}
]}
JSON

: > "${WARN_LOG}"
refresh_meter_files

HEAT="$(cat "${METER_DIR}/meter-0001" 2>/dev/null || echo MISSING)"
if grep -q "^calculate_difftemp_c=flow_temperature_c - return_temperature_c$" <<<"${HEAT}" \
   && grep -q "^calculate_half_m3=total_m3 / 2$" <<<"${HEAT}"; then
  pass "refresh_meter_files writes the calculate_ lines into the meter file"
else
  fail "generated meter file lacks the formulas:"$'\n'"${HEAT}"
fi

if grep -q "^id=03534159$" <<<"${HEAT}" && grep -q "^driver=kamheat$" <<<"${HEAT}"; then
  pass "the existing keys are untouched"
else
  fail "generated meter file lost its usual keys:"$'\n'"${HEAT}"
fi

WATER="$(cat "${METER_DIR}/meter-0002" 2>/dev/null || echo MISSING)"
if ! grep -q "calculate_" <<<"${WATER}"; then
  pass "a meter without formulas gets no calculate_ line"
else
  fail "formulas leaked into another meter:"$'\n'"${WATER}"
fi

# The regeneration itself is what used to destroy hand-written lines; running it
# twice must be idempotent rather than doubling the entries.
refresh_meter_files
if [[ "$(grep -c "^calculate_" "${METER_DIR}/meter-0001")" == "2" ]]; then
  pass "a reload rewrites the same two lines, not four"
else
  fail "reload changed the formula count: $(grep -c '^calculate_' "${METER_DIR}/meter-0001")"
fi

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
