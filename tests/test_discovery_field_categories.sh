#!/usr/bin/env bash
# Regression test: emit_discovery_from_json must publish a Discovery config for
# every field the driver exposes, and split them by what they measure.
#
#   - numeric field with a device_class, or with a consumption unit
#     (m³/GJ/MJ/kWh/Wh/l — heat volume has no HA device_class) -> plain sensor,
#     enabled, keeps unit/device_class/state_class;
#   - anything else (unclassified numbers, text, null) -> diagnostic sensor
#     published with enabled_by_default:false;
#   - "status" keeps its own dedicated sensor + problem binary_sensor;
#   - metadata (id/name/meter/media/timestamp) never becomes an entity.
#
# Background: the field loop used to select only JSON values of type "number"
# and to publish all of them as plain sensors, so a driver reporting its state
# as current_status (apatorna1) or a not-yet-set fraud_date (hydrodigit)
# produced no entity at all, while record ages and error counters landed among
# the measurements.
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

# The jq build shipped for Windows terminates every line with CRLF, so a field
# name read by the code under test arrives as "history_1_date\r" and an
# end-anchored glob such as history_*_date stops matching. The container's jq
# emits LF, so this is a harness concern only — strip it here rather than
# loosening the production matcher for an artefact it never sees.
jq() { command jq "$@" | tr -d '\r'; }

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

METER_ID=""

run_telegram() {
  METER_ID="$1"
  : > "${CAPTURE}"
  # Reset the per-field publish caches declared by 09-discovery.sh so each
  # telegram is evaluated from scratch.
  # shellcheck disable=SC2034
  {
    DISCOVERY_SENT_FIELD=()
    DISCOVERY_CLEANED_LEGACY=()
  }
  emit_discovery_from_json "$2"
}

payload_for() {
  local field="$1"
  awk -F'\t' -v topic="homeassistant/sensor/wmbus_${METER_ID}/${field}/config" \
    '$1 == topic { print $2 }' "${CAPTURE}" | tail -n 1
}

# NB: jq's // treats a literal false as empty, so presence is tested explicitly.
field_prop() {
  jq -r --arg k "$2" 'if has($k) then (.[$k]|tostring) else "missing" end' <<<"$1" 2>/dev/null || echo parse_error
}

assert_diagnostic() {
  local field="$1"
  local payload enabled category
  payload="$(payload_for "${field}")"
  if [[ -z "${payload}" ]]; then
    fail "${field}: no discovery config published"
    return
  fi
  enabled="$(field_prop "${payload}" enabled_by_default)"
  category="$(field_prop "${payload}" entity_category)"
  if [[ "${enabled}" == "false" && "${category}" == "diagnostic" ]]; then
    pass "${field}: diagnostic, disabled by default"
  else
    fail "${field}: enabled_by_default=${enabled} entity_category=${category} (expected false/diagnostic)"
  fi
}

assert_measurement() {
  local field="$1"
  local expected_unit="$2"
  local payload enabled category unit
  payload="$(payload_for "${field}")"
  if [[ -z "${payload}" ]]; then
    fail "${field}: no discovery config published"
    return
  fi
  enabled="$(field_prop "${payload}" enabled_by_default)"
  category="$(field_prop "${payload}" entity_category)"
  unit="$(field_prop "${payload}" unit_of_measurement)"
  if [[ "${enabled}" == "missing" && "${category}" == "missing" && "${unit}" == "${expected_unit}" ]]; then
    pass "${field}: measurement sensor, enabled, unit=${unit}"
  else
    fail "${field}: enabled_by_default=${enabled} entity_category=${category} unit=${unit} (expected missing/missing/${expected_unit})"
  fi
}

assert_no_entity() {
  local field="$1"
  if grep -q -F "homeassistant/sensor/wmbus_${METER_ID}/${field}/config" "${CAPTURE}"; then
    fail "${field}: must not get a discovery config"
  else
    pass "${field}: correctly skipped"
  fi
}

# An excluded field must be actively removed: the topic is published with an
# empty retained payload (the MQTT Discovery removal protocol) and never with a
# config body.
assert_excluded() {
  local field="$1" domain="${2:-sensor}"
  local topic="homeassistant/${domain}/wmbus_${METER_ID}/${field}/config"
  local total empty
  total="$(awk -F'\t' -v t="${topic}" '$1 == t' "${CAPTURE}" | wc -l | tr -d ' ')"
  empty="$(awk -F'\t' -v t="${topic}" '$1 == t && $2 == ""' "${CAPTURE}" | wc -l | tr -d ' ')"
  if [[ "${total}" -ge 1 && "${total}" == "${empty}" ]]; then
    pass "${field}: excluded, config cleared (${total} empty publish)"
  else
    fail "${field}: expected only empty payloads, got ${total} publishes of which ${empty} empty"
  fi
}

# --- apatorna1: text status fields, historic readings, dedicated "status" ----
run_telegram 04913581 '{"_":"telegram","current_status":"OK","frame_status":"SUMMER_TIME","historic_age_h":304,"historic_datetime":"2026-07-31 22:08","historic_m3":1785.804,"historic_status":"MINIMUM_FLOW","id":"04913581","media":"water","meter":"apatorna1","meter_datetime":"2026-08-13 14:08","name":"Cold_Water_3581","status":"OK","timestamp":"2026-08-13T13:22:13Z","total_m3":1798.2}'

assert_measurement total_m3 "m³"
assert_measurement historic_m3 "m³"
for f in current_status frame_status historic_status historic_datetime meter_datetime historic_age_h; do
  assert_diagnostic "${f}"
done
for f in id name meter media timestamp; do
  assert_no_entity "${f}"
done

# The dedicated status block owns .../status/config; the generic loop must not
# publish a second, conflicting config for the same topic.
status_configs="$(awk -F'\t' '$1 == "homeassistant/sensor/wmbus_04913581/status/config"' "${CAPTURE}" | wc -l | tr -d ' ')"
if [[ "${status_configs}" == "1" ]]; then
  pass "status: exactly one config published (dedicated diagnostic sensor)"
else
  fail "status: expected 1 config, got ${status_configs}"
fi

if [[ "$(field_prop "$(payload_for status)" enabled_by_default)" == "missing" ]]; then
  pass "status: dedicated sensor stays enabled by default"
else
  fail "status: dedicated sensor unexpectedly carries enabled_by_default"
fi

if grep -q -F 'homeassistant/binary_sensor/wmbus_04913581/status_problem/config' "${CAPTURE}"; then
  pass "status_problem: binary_sensor still published"
else
  fail "status_problem: binary_sensor missing"
fi

# --- hydrodigit: null-valued fields, battery voltage, text field list --------
run_telegram 03534159 '{"_":"telegram","backflow_m3":3724541.952,"contents":"BACKFLOW BATTERY_VOLTAGE FRAUD_DATE LEAK_DATE","fraud_date":null,"fraud_type":"NO_TYPE_INFO","id":"03534159","leak_date":null,"media":"water","meter":"hydrodigit","meter_datetime":"2026-08-13 15:03","name":"Cold_Water_4159","timestamp":"2026-08-13T13:54:52Z","total_m3":29.984,"voltage_v":3.7}'

assert_measurement total_m3 "m³"
assert_measurement backflow_m3 "m³"
assert_measurement voltage_v "V"
for f in contents fraud_type meter_datetime fraud_date leak_date; do
  assert_diagnostic "${f}"
done

# --- heat meter: m³ and GJ carry no HA device_class but are consumption ------
run_telegram 07331000 '{"_":"telegram","total_m3":412.5,"total_energy_consumption_gj":18.44,"flow_temperature_c":64.2,"max_flow_m3h":1.2,"records_counter":17,"id":"07331000","media":"heat","meter":"kamheat","name":"Heat_1000","timestamp":"2026-08-13T13:54:52Z"}'

assert_measurement total_m3 "m³"
assert_measurement total_energy_consumption_gj "GJ"
assert_measurement flow_temperature_c "°C"
assert_diagnostic max_flow_m3h
assert_diagnostic records_counter

# --- heat cost allocator: hca is the billed reading and has no device_class --
# Captured from a live fhkvdataiii telegram; before is_consumption_unit knew
# "hca" the allocator published only its two temperatures as measurements and
# filed its actual reading as a disabled diagnostic.
run_telegram 32131245 '{"_":"telegram","current_date":"2026-02-15","current_hca":0,"id":"32131245","media":"heat cost allocator","meter":"fhkvdataiii","name":"TESTOWY_1245","previous_date":"2025-12-31","previous_hca":0,"temp_radiator_c":18.09,"temp_room_c":18.22,"timestamp":"2026-08-13T14:30:19Z"}'

assert_measurement current_hca "hca"
assert_measurement previous_hca "hca"
assert_measurement temp_room_c "°C"
assert_diagnostic current_date
assert_diagnostic previous_date

# --- electricity: reactive/apparent energy also carry no HA device_class -----
run_telegram 88776655 '{"_":"telegram","total_energy_consumption_kwh":3861.107,"total_reactive_energy_consumption_kvarh":42.5,"current_power_consumption_kw":0.35,"id":"88776655","media":"electricity","meter":"amiplus","name":"Power_6655","timestamp":"2026-08-13T14:30:19Z"}'

assert_measurement total_energy_consumption_kwh "kWh"
assert_measurement total_reactive_energy_consumption_kvarh "kVARh"
assert_measurement current_power_consumption_kw "kW"

# --- per-meter exclude_fields: glob patterns suppress and remove entities ----
# METER_EXCLUDE_FIELDS is declared by 08-discovery-helpers.sh and filled by
# refresh_meter_files() from options.json; the test fills it directly, which is
# the same contract.
METER_EXCLUDE_FIELDS["21031894"]="consumption_at_history_* history_*_date STATUS"

run_telegram 21031894 '{"_":"telegram","total_m3":118.2,"consumption_at_history_1_m3":9.1,"consumption_at_history_2_m3":8.4,"history_1_date":"2026-07-31","history_2_date":"2026-06-30","current_status":"OK","status":"OK","max_flow_since_datetime_m3h":1.2,"id":"21031894","media":"water","meter":"evo868","name":"TESTOWY_1894","timestamp":"2026-08-13T14:30:19Z"}'

assert_measurement total_m3 "m³"
assert_excluded consumption_at_history_1_m3
assert_excluded consumption_at_history_2_m3
assert_excluded history_1_date
assert_excluded history_2_date
# "status" owns a sensor plus a problem binary_sensor; excluding it must take
# both, and the pattern was written upper-case to prove matching ignores case.
assert_excluded status
assert_excluded status_problem binary_sensor
# Fields outside the patterns keep their normal treatment.
assert_diagnostic current_status
assert_diagnostic max_flow_since_datetime_m3h

# --- no patterns configured: nothing is cleared (guards the default path) ----
# shellcheck disable=SC2034
METER_EXCLUDE_FIELDS=()
run_telegram 03314055 '{"_":"telegram","total_m3":29.9,"target_m3":28.0,"status":"OK","id":"03314055","media":"water","meter":"mkradio4","name":"TESTOWY_4055","timestamp":"2026-08-13T14:30:19Z"}'

assert_measurement total_m3 "m³"
assert_measurement target_m3 "m³"
if [[ "$(field_prop "$(payload_for status)" enabled_by_default)" == "missing" ]]; then
  pass "no exclude_fields: status keeps its dedicated sensor"
else
  fail "no exclude_fields: status sensor was altered"
fi

# --- the catalog parser itself, against real --listfields output -------------
# Injecting FIELD_CATALOG (as the block below does) skips load_field_catalog,
# and that is exactly where a bug hid once: the parser used GNU sed's "\t"
# replacement, which busybox sed in the Alpine add-on image does not perform.
# This case runs the parser over a stub that reproduces the real column layout,
# padding and all.
STUB_BIN="${WORK_DIR}/wmbusmeters"
cat > "${STUB_BIN}" <<'STUB'
#!/usr/bin/env bash
cat <<'OUT'
                                                  id  The meter id number.
                                            total_m3  The total media volume consumption recorded by this meter.
                         max_flow_since_datetime_m3h  Maximum water flow since date time.
consumption_at_history_{storage_counter-7counter}_m3  The total water consumption at the historic date.
                                         va_counter
OUT
STUB
chmod +x "${STUB_BIN}"
# shellcheck disable=SC2034
WMBUSMETERS_BIN="${STUB_BIN}"
load_field_catalog "stubdriver"

assert_catalog() {
  local key="$1" expect="$2"
  local got="${FIELD_CATALOG[stubdriver|${key}]-<missing>}"
  if [[ "${got}" == "${expect}" ]]; then
    pass "catalog: ${key} parsed"
  else
    fail "catalog: ${key} -> '${got}' (expected '${expect}')"
  fi
}

assert_catalog "total_m3" "The total media volume consumption recorded by this meter."
assert_catalog "max_flow_since_datetime_m3h" "Maximum water flow since date time."
assert_catalog "consumption_at_history_{storage_counter-7counter}_m3" "The total water consumption at the historic date."
# A field with no description must still land in the catalog, with empty text.
assert_catalog "va_counter" ""

# And the glob lookup has to resolve a concrete field through the templated key.
if [[ "$(field_description "stubdriver" "consumption_at_history_7_m3")" == "The total water consumption at the historic date." ]]; then
  pass "catalog: templated entry matches a concrete field name"
else
  fail "catalog: templated entry did not match consumption_at_history_7_m3"
fi

# --- field descriptions become an entity attribute ---------------------------
# FIELD_CATALOG is normally filled by load_field_catalog() from
# `wmbusmeters --listfields`; the test fills it directly, which is the same
# contract and keeps the suite independent of the decoder binary. The catalog
# uses templated names for repeated fields, so one entry must cover
# consumption_at_history_1_m3 as well as _2_m3.
# shellcheck disable=SC2034
{
  FIELD_CATALOG["evo868|total_m3"]="The total media volume consumption recorded by this meter."
  FIELD_CATALOG["evo868|consumption_at_history_{storage_counter-7counter}_m3"]="The total water consumption at the historic date."
  FIELD_CATALOG_LOADED["evo868"]=1
}

run_telegram 21031894 '{"_":"telegram","total_m3":118.2,"consumption_at_history_1_m3":9.1,"set_date":"2026-01-31","id":"21031894","media":"water","meter":"evo868","name":"TESTOWY_1894","timestamp":"2026-08-14T14:30:19Z"}'

assert_attr_description() {
  local field="$1" expect="$2"
  local payload tpl
  payload="$(payload_for "${field}")"
  tpl="$(field_prop "${payload}" json_attributes_template)"
  if [[ "${tpl}" == *"Description=\"${expect}\""* && "${tpl}" == *"dict(value_json"* ]]; then
    pass "${field}: description merged into the attributes template"
  else
    fail "${field}: unexpected json_attributes_template: ${tpl}"
  fi
}

assert_attr_description total_m3 "The total media volume consumption recorded by this meter."
# Templated catalog entry has to match the concrete field name.
assert_attr_description consumption_at_history_1_m3 "The total water consumption at the historic date."

# A field the catalog does not describe keeps the plain pass-through, so the
# whole telegram still reaches the entity attributes.
if [[ "$(field_prop "$(payload_for set_date)" json_attributes_template)" == "missing" ]]; then
  pass "set_date: no description, attributes pass through unchanged"
else
  fail "set_date: got a json_attributes_template without a description"
fi

# Every published config must stay valid JSON — the description is embedded in a
# Jinja string literal inside it.
if awk -F'\t' '$2 != "" {print $2}' "${CAPTURE}" | jq -e . >/dev/null 2>&1; then
  pass "all published configs are valid JSON"
else
  fail "a published config is not valid JSON"
fi

# --- opt-in per-meter RSSI joined onto the telegram ---------------------------
# inject_rssi_into_json lives at file scope in 13-esp.sh on purpose: defined
# inside start_esp_subscribers() it would only exist after that function ran,
# an invisible ordering dependency. Sourcing the library here proves it is
# callable without starting any subscriber.
# shellcheck source=/dev/null
source "${LIB_DIR}/13-esp.sh"
STATUS_RSSI_FILE="${WORK_DIR}/status_rssi.tsv"
TELEGRAM_RSSI='{"_":"telegram","total_m3":10.5,"id":"21031894","media":"water","meter":"evo868","name":"M","timestamp":"2026-08-14T14:30:19Z"}'

assert_json_field() {
  local label="$1" json="$2" key="$3" expect="$4"
  local got
  got="$(jq -r --arg k "${key}" 'if has($k) then (.[$k]|tostring) else "missing" end' <<<"${json}" 2>/dev/null || echo parse_error)"
  if [[ "${got}" == "${expect}" ]]; then
    pass "${label}: ${key}=${got}"
  else
    fail "${label}: ${key}=${got} (expected ${expect})"
  fi
}

# No file at all — the normal install, where the firmware never publishes RSSI.
rm -f "${STATUS_RSSI_FILE}"
assert_json_field "no rssi file" "$(inject_rssi_into_json 21031894 "${TELEGRAM_RSSI}")" rssi_dbm missing

# Fresh row: value and its source are both joined in.
printf '%s\t%s\t%s\t%s\n' "21031894" "-78" "esphome-wmbus-lilygo" "$(epoch_now)" > "${STATUS_RSSI_FILE}"
RSSI_JOINED="$(inject_rssi_into_json 21031894 "${TELEGRAM_RSSI}")"
assert_json_field "fresh rssi" "${RSSI_JOINED}" rssi_dbm -78
assert_json_field "fresh rssi" "${RSSI_JOINED}" rssi_source esphome-wmbus-lilygo
assert_json_field "fresh rssi" "${RSSI_JOINED}" total_m3 10.5

# A row for a different meter must not leak onto this one.
assert_json_field "other meter" "$(inject_rssi_into_json 03534159 "${TELEGRAM_RSSI}")" rssi_dbm missing

# Stale row: the firmware stopped publishing while still forwarding telegrams.
printf '%s\t%s\t%s\t%s\n' "21031894" "-78" "esphome-wmbus-lilygo" "$(( $(epoch_now) - RSSI_MAX_AGE_S - 1 ))" > "${STATUS_RSSI_FILE}"
assert_json_field "stale rssi" "$(inject_rssi_into_json 21031894 "${TELEGRAM_RSSI}")" rssi_dbm missing

# The firmware marks "no valid sample" with different sentinels per topic
# (1 in health, 0 in the window topics, -127 = RSSI_NOT_MEASURED in the driver).
# None of them may ever be joined on as if it were a reading.
for sentinel in 1 0 -127 -126; do
  printf '%s	%s	%s	%s
' "21031894" "${sentinel}" "dev" "$(epoch_now)" > "${STATUS_RSSI_FILE}"
  assert_json_field "sentinel ${sentinel}" "$(inject_rssi_into_json 21031894 "${TELEGRAM_RSSI}")" rssi_dbm missing
done

# Garbage from a misconfigured publisher must never reach the payload.
printf '%s\t%s\t%s\t%s\n' "21031894" "not-a-number" "dev" "$(epoch_now)" > "${STATUS_RSSI_FILE}"
assert_json_field "malformed rssi" "$(inject_rssi_into_json 21031894 "${TELEGRAM_RSSI}")" rssi_dbm missing

# End to end: the joined field goes through the ordinary Discovery path —
# rssi_dbm gets an entity (dBm implies signal_strength), rssi_source does not,
# because provenance belongs in the attributes rather than in its own sensor.
printf '%s\t%s\t%s\t%s\n' "21031894" "-78" "esphome-wmbus-lilygo" "$(epoch_now)" > "${STATUS_RSSI_FILE}"
# shellcheck disable=SC2034
METER_EXCLUDE_FIELDS=()
run_telegram 21031894 "$(inject_rssi_into_json 21031894 "${TELEGRAM_RSSI}")"
assert_measurement rssi_dbm "dBm"
assert_no_entity rssi_source

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
