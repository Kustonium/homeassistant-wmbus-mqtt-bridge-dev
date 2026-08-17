#!/usr/bin/env bash
# Regression test: wired M-Bus configuration generation.
#
# Two properties here are not cosmetic, both established by measurement against
# a real bus simulator:
#
#   1. pollinterval MUST land in every meter file. It is not a key of
#      wmbusmeters.conf - the global parser answers "No such key: pollinterval"
#      and carries on - and --pollinterval cannot be combined with --useconfig.
#      A meter file without it is never polled, and a meter that is never polled
#      is indistinguishable from a dead one.
#
#   2. The driver spec must carry the bus alias (driver:ALIAS:mbus). That is
#      what binds the meter to the bus and marks it pollable; without it the
#      decoder logs "no bus specified for meter".
#
# Also checked: address validation (p0 and p251 are not valid - p0 is the
# factory "unset" value, valid primaries are p1..p250), and that no meter file
# is produced for a rejected entry.
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
err()  { printf '%s\n' "$*" >> "${WARN_LOG}"; }
log() { :; }
log_verbose() { :; }
status_add_event() { :; }
epoch_now() { date +%s; }

BASE="${WORK_DIR}"
OPTIONS_JSON="${BASE}/options.json"

# shellcheck source=/dev/null
source "${LIB_DIR}/07-meters.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/14-mbus.sh"

mbus_init_paths
mkdir -p "${MBUS_METER_DIR}"

cat > "${OPTIONS_JSON}" <<'EOFJSON'
{
  "mbus_enabled": true,
  "mbus_bus_alias": "MAIN",
  "mbus_poll_interval": "15m",
  "mbus_meters": [
    {"id": "heat", "address": "p1", "type": "piigth"},
    {"id": "water", "address": "68123456", "type": "kamwater", "poll_interval": "1h"},
    {"id": "auto_one", "address": "p250"},
    {"id": "bad_zero", "address": "p0", "type": "piigth"},
    {"id": "bad_high", "address": "p251", "type": "piigth"},
    {"id": "calc", "address": "p7", "type": "piigth",
     "calculated_fields": "difftemp_c=flow_temperature_c-return_temperature_c"}
  ]
}
EOFJSON

# Read by refresh_mbus_meter_files() in the sourced module.
# shellcheck disable=SC2034
MBUS_BUS_ALIAS="MAIN"
refresh_mbus_meter_files

# Glob the real files only. A plain meter-* also matches meter-NNNN.tmp, which
# is how an earlier version of this test reported PASS while every real file
# was missing: the brace group returned 1, the `&& mv` never ran and only the
# temporary files existed.
mapfile -t files < <(find "${MBUS_METER_DIR}" -maxdepth 1 -name 'meter-[0-9]*' ! -name '*.tmp' | sort)
if [[ "${#files[@]}" -eq 4 ]]; then
  pass "4 meter files written (2 invalid addresses rejected)"
else
  fail "expected 4 meter files, got ${#files[@]}"
fi

if ! find "${MBUS_METER_DIR}" -maxdepth 1 -name '*.tmp' | grep -q .; then
  pass "no .tmp leftovers - every write was committed with mv"
else
  fail ".tmp files left behind - the atomic write did not complete"
fi

all="$(cat "${files[@]}" 2>/dev/null || true)"

# 1. pollinterval in every file, no exceptions.
missing_poll=0
for file in "${files[@]}"; do
  grep -q '^pollinterval=' "${file}" || missing_poll=$(( missing_poll + 1 ))
done
if [[ "${missing_poll}" -eq 0 ]]; then
  pass "every meter file carries pollinterval"
else
  fail "${missing_poll} meter file(s) without pollinterval - they would never be polled"
fi

if grep -q '^pollinterval=1h$' "${files[@]}" ; then
  pass "per-meter poll_interval overrides the default"
else
  fail "per-meter poll_interval=1h not written"
fi
if [[ "$(grep -c '^pollinterval=15m$' "${files[@]}" | awk -F: '{s+=$NF} END {print s+0}')" -ge 3 ]]; then
  pass "meters without their own interval inherit the default"
else
  fail "default interval 15m not inherited"
fi

# 2. bus alias in the driver spec.
if grep -q '^driver=piigth:MAIN:mbus$' "${files[@]}"; then
  pass "driver spec carries the bus alias"
else
  fail "driver spec without bus alias - decoder would log 'no bus specified'"
fi
if grep -q '^driver=auto:MAIN:mbus$' "${files[@]}"; then
  pass "driver=auto also bound to the bus"
else
  fail "auto driver not bound to the bus"
fi

# 3. Addresses.
if grep -q '^id=p1$' "${files[@]}" && grep -q '^id=68123456$' "${files[@]}"; then
  pass "primary and secondary addresses written verbatim"
else
  fail "addresses not written as configured"
fi
if ! printf '%s' "${all}" | grep -q 'p0$' && ! printf '%s' "${all}" | grep -q 'p251'; then
  pass "p0 and p251 rejected"
else
  fail "invalid address reached a meter file"
fi
if grep -q 'invalid address' "${WARN_LOG}"; then
  pass "invalid addresses warned about"
else
  fail "no warning for invalid addresses"
fi

# 4. calculate_ still passes through on this path too.
if grep -q '^calculate_difftemp_c=' "${files[@]}"; then
  pass "calculated_fields survive into the M-Bus meter file"
else
  fail "calculated_fields dropped"
fi

# 5. No warning text may end up inside a meter file.
if ! grep -qi 'invalid\|skipped' "${files[@]}"; then
  pass "no warning text leaked into meter files"
else
  fail "warning text found inside a meter file"
fi

# 6. wmbusmeters.conf must NOT carry pollinterval (silently ignored there).
cat > "${OPTIONS_JSON}.dev" <<'EOFJSON'
{"mbus_device": "/dev/null", "mbus_bus_alias": "MAIN", "mbus_baudrate": "2400",
 "mbus_poll_interval": "15m", "mbus_donotprobe_all": true}
EOFJSON
mv "${OPTIONS_JSON}.dev" "${OPTIONS_JSON}"
if write_mbus_conf; then
  if grep -q '^device=MAIN=/dev/null:mbus:2400$' "${MBUS_CONF_FILE}"; then
    pass "device spec written with alias and baud rate"
  else
    fail "device spec malformed: $(grep '^device=' "${MBUS_CONF_FILE}" || true)"
  fi
  if ! grep -q '^pollinterval=' "${MBUS_CONF_FILE}"; then
    pass "wmbusmeters.conf free of pollinterval (not a key there)"
  else
    fail "pollinterval written into wmbusmeters.conf - silently ignored by the decoder"
  fi
  if grep -q '^donotprobe=all$' "${MBUS_CONF_FILE}"; then
    pass "donotprobe=all written"
  else
    fail "donotprobe=all missing"
  fi
else
  fail "write_mbus_conf failed for a valid device"
fi

# 7. Meter counts are reported, not just logged. The WebUI's bus-status card
# reads them out of status_mbus.json; a rejected entry that is only warned
# about in the log is indistinguishable, in the UI, from a meter that is being
# polled and stays silent.
if [[ "${MBUS_METERS_OK}" -eq 4 && "${MBUS_METERS_SKIPPED}" -eq 2 ]]; then
  pass "meter counts reported (4 written, 2 rejected)"
else
  fail "meter counts wrong: ok=${MBUS_METERS_OK} skipped=${MBUS_METERS_SKIPPED}"
fi

# 8. A malformed poll interval must not reach a meter file. The options schema
# takes a free string, so the add-on options page accepts "15" as readily as
# "15m" - and the decoder then never polls that meter, which looks exactly like
# a dead one.
cat > "${OPTIONS_JSON}" <<'EOFJSON'
{
  "mbus_enabled": true,
  "mbus_device": "/dev/null",
  "mbus_bus_alias": "MAIN",
  "mbus_baudrate": "2400",
  "mbus_poll_interval": "15",
  "mbus_meters": [
    {"id": "bad_poll", "address": "p3", "type": "piigth", "poll_interval": "soon"}
  ]
}
EOFJSON
write_mbus_conf >/dev/null 2>&1 || true
if [[ "${MBUS_POLL_DEFAULT}" == "15m" ]]; then
  pass "malformed global poll interval falls back to 15m"
else
  fail "malformed global poll interval kept as '${MBUS_POLL_DEFAULT}'"
fi
refresh_mbus_meter_files
mapfile -t files2 < <(find "${MBUS_METER_DIR}" -maxdepth 1 -name 'meter-[0-9]*' ! -name '*.tmp' | sort)
if [[ "${#files2[@]}" -eq 1 ]] && grep -q '^pollinterval=15m$' "${files2[0]}"; then
  pass "malformed per-meter poll interval falls back instead of dropping the meter"
else
  fail "malformed per-meter poll interval not handled: $(grep '^pollinterval=' "${files2[@]}" 2>/dev/null || true)"
fi

# 9. The runtime status file. Everything the bus-status card knows travels
# through it: the traffic state lives in the subshell reading the decoder's
# output, so a function returning it could never be called from anywhere else.
# It appears when there is something to report - a successful configuration
# write says nothing about the bus yet, so nothing is written there either.
if [[ ! -f "${MBUS_STATUS_FILE}" ]]; then
  pass "no status file before the engine reports anything"
else
  fail "status file written before there was any state to report"
fi

# Armed with no port: reachable only through the add-on options page, which has
# no way to enforce "pick a port first". The refusal has to be visible in the
# UI, not only as a line in the log.
cat > "${OPTIONS_JSON}" <<'EOFJSON'
{"mbus_enabled": true, "mbus_device": "", "mbus_bus_alias": "MAIN"}
EOFJSON
if write_mbus_conf >/dev/null 2>&1; then
  fail "write_mbus_conf started with no port configured"
else
  if [[ "$(jq -r '.state' "${MBUS_STATUS_FILE}")" == "not_configured" ]]; then
    pass "armed without a port reports not_configured"
  else
    fail "armed without a port reported '$(jq -r '.state' "${MBUS_STATUS_FILE}")'"
  fi
fi
if jq -e . "${MBUS_STATUS_FILE}" >/dev/null 2>&1; then
  pass "status file is valid JSON"
else
  fail "status file malformed: ${MBUS_STATUS_FILE}"
fi
if ! find "${BASE}" -maxdepth 1 -name 'status_mbus.json.tmp' | grep -q .; then
  pass "no status_mbus.json.tmp leftover - the atomic write completed"
else
  fail "status_mbus.json.tmp left behind"
fi

# A vanished port is the expected outcome of moving the converter to another
# USB socket, and must be told apart from a silent bus.
cat > "${OPTIONS_JSON}" <<'EOFJSON'
{"mbus_enabled": true, "mbus_device": "/dev/does-not-exist-mbus", "mbus_bus_alias": "MAIN"}
EOFJSON
if write_mbus_conf >/dev/null 2>&1; then
  fail "write_mbus_conf started on a nonexistent device"
else
  if [[ "$(jq -r '.state' "${MBUS_STATUS_FILE}")" == "device_missing" ]]; then
    pass "vanished port reports device_missing"
  else
    fail "vanished port reported '$(jq -r '.state' "${MBUS_STATUS_FILE}")'"
  fi
fi

# The address clash: one polled address answering with two different ids. The
# decoder reports neither problem nor duplicate - it simply emits both - so
# without this the user gets a second device in Home Assistant from one entry.
normalize_meter_id() { printf '%s' "$1"; }
emit_discovery_from_json() { :; }
STATUS_METER_SEEN_CALLS=0
status_meter_seen() { STATUS_METER_SEEN_CALLS=$(( STATUS_METER_SEEN_CALLS + 1 )); }
mqtt_pub() { :; }
status_mark_discovery_published() { :; }
write_status_json() { :; }
# Read by mbus_consume_line() in the sourced module.
# shellcheck disable=SC2034
STATE_PREFIX="wmbusmeters"
# shellcheck disable=SC2034
STATE_RETAIN="true"
mbus_consume_line '{"_":"telegram","name":"sim","id":"10000284","total_m3":1.5}' >/dev/null
mbus_consume_line '{"_":"telegram","name":"sim","id":"77000284","total_m3":9.9}' >/dev/null
if [[ "${STATUS_METER_SEEN_CALLS}" -eq 2 ]]; then
  pass "accepted wired telegrams feed the shared WebUI meter status"
else
  fail "wired telegram status calls: ${STATUS_METER_SEEN_CALLS}, expected 2"
fi
if [[ "$(jq -r '.meters.sim.clash_with' "${MBUS_STATUS_FILE}")" == "10000284" ]]; then
  pass "address clash recorded against the meter"
else
  fail "address clash not recorded: $(jq -c '.meters' "${MBUS_STATUS_FILE}")"
fi
if [[ "$(jq -r '.meters.sim.last_ok_epoch' "${MBUS_STATUS_FILE}")" -gt 0 ]]; then
  pass "last successful reply timestamped from arrival"
else
  fail "no last_ok_epoch recorded"
fi
if [[ "$(jq -r '.state' "${MBUS_STATUS_FILE}")" == "ok" ]]; then
  pass "an accepted telegram moves the state to ok"
else
  fail "state after a telegram: $(jq -r '.state' "${MBUS_STATUS_FILE}")"
fi

# A named cause outranks plain silence: once foreign bytes are on the wire,
# "no reply" would hide the one line that explains the whole symptom.
mbus_consume_line 'wmbusmeters: no 0x68 byte found' >/dev/null
mbus_consume_line 'wmbusmeters: meter sim did not send a response!' >/dev/null
if [[ "$(jq -r '.state' "${MBUS_STATUS_FILE}")" == "not_mbus_traffic" ]]; then
  pass "foreign traffic is not overwritten by a later silence"
else
  fail "state should stay not_mbus_traffic, got $(jq -r '.state' "${MBUS_STATUS_FILE}")"
fi

echo
echo "passed=${PASS} failed=${FAIL}"
[[ "${FAIL}" -eq 0 ]]
