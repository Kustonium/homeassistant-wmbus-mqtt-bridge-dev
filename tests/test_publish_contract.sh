#!/usr/bin/env bash
# Contract test: everything the add-on publishes to the broker for a fixed set
# of decoded telegrams - topic, retain flag and payload, in order - must match
# tests/fixtures/publish_contract/expected.tsv byte for byte.
#
# Why: the publishing code moves from bash to Python in parts (Discovery,
# states, the coverage sensor, the canary). Home Assistant builds entity ids
# and devices from these topics and payloads, so a rewrite that changes one
# byte of them changes or duplicates entities for every user. This file pins
# today's output; each part of the rewrite has to reproduce it.
#
# The real bridge-lib code runs. Only its edges are replaced: the clock is
# fixed, the reception statistics behind expire_after are fixed, and the
# decoder's field catalog comes from fixtures/publish_contract/listfields/
# (recorded from the pinned binary by gen_corpus.sh). What leaves mqtt_pub is
# recorded in one of two ways:
#
#   default                     mqtt_pub is replaced by a recorder;
#   CONTRACT_TRANSPORT=publisher the real mqtt_pub hands every message to the
#                               real mqtt_publisher.py, which sends it to
#                               tests/helpers/fake_mqtt_broker.py - so the bytes
#                               a broker receives are checked against the same
#                               file.
#
# Not covered yet: the wired M-Bus state path (14-mbus.sh) and the SEARCH
# match payload (10-search.sh) - added with the parts that rewrite them.
#
# After an intended change in what is published, regenerate and review:
#   CONTRACT_UPDATE=1 tests/test_publish_contract.sh && git diff tests/fixtures/publish_contract/
#
# The scenarios set options that only the sourced bridge-lib code reads.
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
[[ "${SCRIPT_DIR}" == "${SCRIPT_PATH}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_DIR="${ROOT_DIR}/rootfs/usr/bin/bridge-lib"
FIX="${SCRIPT_DIR}/fixtures/publish_contract"
EXPECTED="${FIX}/expected.tsv"

fail() { echo "FAIL: $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || fail "missing jq"

WORK="$(mktemp -d)"
BROKER_PID=""
MQTT_PUBLISHER_PID=""
cleanup() {
  local kids=""
  if [[ -n "${MQTT_PUBLISHER_PID}" ]]; then
    kids="$(pgrep -P "${MQTT_PUBLISHER_PID}" 2>/dev/null || true)"
    kill "${MQTT_PUBLISHER_PID}" 2>/dev/null || true
    # shellcheck disable=SC2086  # a list of pids
    [[ -z "${kids}" ]] || kill ${kids} 2>/dev/null || true
  fi
  [[ -z "${BROKER_PID}" ]] || kill "${BROKER_PID}" 2>/dev/null || true
  rm -rf "${WORK}"
}
trap cleanup EXIT
TRANSPORT="${CONTRACT_TRANSPORT:-recorder}"
[[ "${TRANSPORT}" == "recorder" || "${TRANSPORT}" == "publisher" ]] \
  || fail "CONTRACT_TRANSPORT must be recorder or publisher, not ${TRANSPORT}"
CAPTURE="${WORK}/published.tsv"
: > "${CAPTURE}"

{
  BASE="${WORK}"
  RUNTIME="${WORK}"
  DISCOVERY_ENABLED="true"
  DISCOVERY_PREFIX="homeassistant"
  DISCOVERY_RETAIN="true"
  STATE_PREFIX="wmbusmeters"
  STATE_RETAIN="false"
  REQUIRE_TIMESTAMP="false"
  SEARCH_MODE="false"
  VERIFY_HA_ENTITIES="false"
  STATUS_RSSI_FILE="${WORK}/status_rssi.tsv"
  STATUS_ESP_RX_RECEPTION_FILE="${WORK}/status_esp_rx_reception.tsv"
}

for f in "${LIB_DIR}"/[0-9][0-9]-*.sh; do
  # shellcheck source=/dev/null
  source "${f}"
done

# ── edges ───────────────────────────────────────────────────────────────────
SCENARIO=""
FAKE_NOW=1790000000
SEEN_AVG=0
MARKER="__contract__/scenario"
SYNC_MARKER="__contract__/sync"
if [[ "${TRANSPORT}" == "recorder" ]]; then
  mqtt_pub() {
    local retain="false"
    [[ "${3:-false}" == "true" ]] && retain="true"
    printf '%s\t%s\t%s\t%s\n' "${SCENARIO}" "$1" "${retain}" "$2" >> "${CAPTURE}"
    return 0
  }
  scenario() { SCENARIO="$1"; }
else
  command -v python3 >/dev/null 2>&1 || fail "missing python3"
  BROKER_OUT="${WORK}/broker.tsv"
  : > "${BROKER_OUT}"
  python3 "${SCRIPT_DIR}/helpers/fake_mqtt_broker.py" "${WORK}/broker.port" "${BROKER_OUT}" &
  BROKER_PID=$!
  for _ in $(seq 50); do [[ -s "${WORK}/broker.port" ]] && break; sleep 0.1; done
  [[ -s "${WORK}/broker.port" ]] || fail "fake broker did not start"
  MQTT_HOST="127.0.0.1"
  MQTT_PORT="$(< "${WORK}/broker.port")"
  MQTT_USER=""
  MQTT_PASS=""
  # mosquitto_pub must never be needed: a message that falls back to it is
  # missing from what the broker received, and the compare below fails.
  PUB_ARGS=( -h 127.0.0.1 -p 1 )
  MQTT_PUBLISHER="${ROOT_DIR}/rootfs/usr/bin/mqtt_publisher.py"
  # The broker sees one stream; a marker message labels what follows.
  scenario() { SCENARIO="$1"; mqtt_pub "${MARKER}" "$1" "false"; }
fi
epoch_now() { echo "${FAKE_NOW}"; }
iso_now() { echo "2026-10-06T08:00:00Z"; }
status_seen_stats() { printf '%s\t%s\t%s\t%s\n' 12 "${SEEN_AVG}" 3 10; }
status_mark_discovery_published() { :; }
write_status_json() { :; }
status_meter_seen() { :; }
status_add_event() { :; }
log() { :; }
warn() { :; }

# The decoder's field catalog, recorded per driver.
WMBUSMETERS_BIN="${WORK}/wmbusmeters"
printf '#!/usr/bin/env bash\ncat "%s/listfields/${1#--listfields=}.txt" 2>/dev/null | tr -d "\\r"\n' "${FIX}" > "${WMBUSMETERS_BIN}"
chmod +x "${WMBUSMETERS_BIN}"

# The publisher builds Discovery of decoded telegrams in Python
# (wmbus_discovery.py); it reads the fixed clock and average interval from a
# file, written before every decoded telegram.
export MQTT_PUBLISHER_TEST_STATE="${WORK}/publisher_test_state"
sync_test_state() {
  printf '%s\n' "NOW=${FAKE_NOW}" "SEEN_AVG=${SEEN_AVG}" \
    "DISCOVERY_ENABLED=${DISCOVERY_ENABLED}" "DISCOVERY_RETAIN=${DISCOVERY_RETAIN}" \
    "STATE_RETAIN=${STATE_RETAIN}" "REQUIRE_TIMESTAMP=${REQUIRE_TIMESTAMP}" \
    > "${MQTT_PUBLISHER_TEST_STATE}"
}
sync_test_state
eval "$(declare -f publish_decoded_json | sed '1s/^publish_decoded_json/_contract_publish_decoded_json/')"
# The publisher reads the RSSI and test-state files when it handles a
# telegram, which can be after bash has moved on to the next scenario. Wait
# until the broker has everything of this telegram, so each one sees the
# state its scenario set.
SYNC_N=0
publish_decoded_json() {
  sync_test_state
  _contract_publish_decoded_json "$@"
  [[ "${TRANSPORT}" == "publisher" ]] || return 0
  SYNC_N=$(( SYNC_N + 1 ))
  mqtt_pub "${SYNC_MARKER}" "${SYNC_N}" "false"
  local _i
  for (( _i = 0; _i < 200; _i++ )); do
    grep -q -F "${SYNC_MARKER}"$'\tfalse\t'"${SYNC_N}" "${BROKER_OUT}" && return 0
    sleep 0.02
  done
  fail "the broker did not receive telegram ${SYNC_N} of scenario ${SCENARIO}"
}
if [[ "${TRANSPORT}" == "publisher" ]]; then
  # Publishing only: the ESP subscriptions are tests/test_publisher_books.py's.
  MQTT_PUBLISHER_SUBSCRIBE=false start_mqtt_publisher
  [[ -n "${MQTT_PUB_PORT}" ]] || fail "mqtt_publisher.py did not start"
  [[ "${MQTT_PUB_DEC}" == "true" || "${MQTT_PYTHON_DISCOVERY:-true}" != "true" ]] \
    || fail "mqtt_publisher.py did not announce Discovery (dec)"
fi

# clear_meter_discovery asks the broker which configs are retained, through
# `timeout 5 /usr/bin/mosquitto_sub`; answer from RETAINED_TOPICS instead.
RETAINED_TOPICS=""
timeout() {
  shift
  if [[ "$1" == */mosquitto_sub ]]; then
    [[ -z "${RETAINED_TOPICS}" ]] || printf '%s\n' "${RETAINED_TOPICS}"
    return 0
  fi
  "$@"
}

reset_caches() {
  # Declared and read in 08/09-discovery*.sh.
  DISCOVERY_SENT_FIELD=()
  DISCOVERY_CLEANED_LEGACY=()
  SEARCH_DISCOVERY_CLEARED_FIELD=()
  METER_EXCLUDE_FIELDS=()
  ESP_COVERAGE_CFG_SENT=()
  ESP_COVERAGE_PUBLISHED=()
  ESP_COVERAGE_PUBLISHED_S=()
  ESP_COVERAGE_LAST_S=0
  : > "${STATUS_RSSI_FILE}"
  mqtt_reset_discovery
}

corpus() { cat "${FIX}/decoded.jsonl" "${FIX}/extra.jsonl" | tr -d '\r'; }
line_for() { corpus | jq -c --arg id "$1" 'select(.id == $id)' | head -n 1; }
publish_all() {
  local line
  while IFS= read -r line; do
    [[ -n "${line}" ]] && publish_decoded_json "${line}"
  done < <(corpus)
}

# ── scenarios ───────────────────────────────────────────────────────────────
# Every decoded telegram once, nothing cached: all Discovery configs + states.
scenario first; reset_caches
publish_all

# The same telegrams again: configs are cached, only states go out.
scenario repeat
publish_all

# The meter's average interval grows: expire_after changes, configs are resent.
scenario expire_after; SEEN_AVG=2400
publish_decoded_json "$(line_for 04913581)"
SEEN_AVG=0

# Disabled Discovery: states only.
scenario discovery_off; reset_caches; DISCOVERY_ENABLED="false"
publish_decoded_json "$(line_for 03314055)"
DISCOVERY_ENABLED="true"

# Retained states and non-retained configs (both options flipped).
scenario retain_flipped; reset_caches; STATE_RETAIN="true"; DISCOVERY_RETAIN="false"
publish_decoded_json "$(line_for 03314055)"
STATE_RETAIN="false"; DISCOVERY_RETAIN="true"

# A required timestamp: the telegram without one is not published at all.
scenario require_timestamp; reset_caches; REQUIRE_TIMESTAMP="true"
publish_decoded_json "$(line_for 11111111)"
publish_decoded_json "$(line_for 03314055)"
REQUIRE_TIMESTAMP="false"

# Per-board RSSI joined on: two fresh boards, one stale, one other meter.
scenario rssi; reset_caches
{
  printf '%s\t%s\t%s\t%s\n' 21031894 -72 lilygo "$(( FAKE_NOW - 10 ))"
  printf '%s\t%s\t%s\t%s\n' 21031894 -65 xiao-seed "$(( FAKE_NOW - 20 ))"
  printf '%s\t%s\t%s\t%s\n' 21031894 -80 heltec "$(( FAKE_NOW - RSSI_MAX_AGE_S - 1 ))"
  printf '%s\t%s\t%s\t%s\n' 03314055 -90 lilygo "$(( FAKE_NOW - 10 ))"
} > "${STATUS_RSSI_FILE}"
publish_decoded_json "$(line_for 21031894)"
publish_decoded_json "$(line_for 21031894)"

# Fields excluded per meter (globs, case-insensitive, "status" takes the pair).
scenario exclude; reset_caches
METER_EXCLUDE_FIELDS["21031894"]="consumption_at_history_* HISTORY_*_DATE"
METER_EXCLUDE_FIELDS["0abcdbee"]="status target_*"
publish_decoded_json "$(line_for 21031894)"
publish_decoded_json "$(line_for 0abcdbee)"
publish_decoded_json "$(line_for 21031894)"

# A SEARCH temporary meter: its entities are cleared, never created.
scenario search_temp; reset_caches; SEARCH_MODE="true"
search_line="$(line_for 0abcdbee | jq -c '.name = "search_0abcdbee"')"
is_search_temp_json "${search_line}" && clear_search_discovery_from_json "${search_line}"
clear_search_discovery_from_json "${search_line}"   # cached: nothing more
SEARCH_MODE="false"

# Factory reset of one meter: every retained config the broker reports.
scenario clear_meter; reset_caches
RETAINED_TOPICS="homeassistant/sensor/wmbus_03314055/total_m3/config {}
homeassistant/sensor/wmbus_03314055/target_m3/config {}
homeassistant/binary_sensor/wmbus_03314055/status_problem/config {}
homeassistant/sensor/wmbus_99999999/total_m3/config {}"
clear_meter_discovery 03314055
RETAINED_TOPICS=""

# Per-board coverage sensor over time, one scenario per call. The boards of
# one call come out in awk's hash order (gawk, mawk and busybox differ), so
# the compare below sorts the rows of each coverage@ call by topic.
reset_caches
{
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' 21031894 lilygo 100 200 5 wmbus/lilygo/rx
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' 03314055 lilygo 100 200 3 wmbus/lilygo/rx
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' 03314055 heltec 100 200 2 wmbus/heltec/rx
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' 67433753 xiao-seed 100 200 1 wmbus/xiao-seed/rx
} > "${STATUS_ESP_RX_RECEPTION_FILE}"
t0="${FAKE_NOW}"
coverage_at() {  # $1 = seconds after the first call
  FAKE_NOW=$(( t0 + $1 )); scenario "coverage@$1"
  publish_esp_coverage
}
coverage_at 0
coverage_at 30      # throttled: nothing
coverage_at 61      # nothing changed: nothing
printf '%s\t%s\t%s\t%s\t%s\t%s\n' 52632878 heltec 100 200 4 wmbus/heltec/rx >> "${STATUS_ESP_RX_RECEPTION_FILE}"
coverage_at 122
coverage_at $(( 122 + ESP_COVERAGE_REFRESH_S ))
FAKE_NOW="${t0}"

# The canary entity of the opt-in HA verification.
scenario canary; reset_caches; VERIFY_HA_ENTITIES="true"
publish_canary_entity
VERIFY_HA_ENTITIES="false"

# ── compare ─────────────────────────────────────────────────────────────────
# Publish order is part of the contract (a config before the state it
# describes), except within one coverage@ call - see above.
normalize() {
  awk -F'\t' 'BEGIN { OFS = "\t" }
    {
      unordered = ($1 ~ /^coverage@/)
      g = unordered ? $1 : $1 "#" NR
      if (!(g in first)) first[g] = NR
      print first[g], (unordered ? $2 : ""), NR, $0
    }' | sort -t $'\t' -k1,1n -k2,2 -k3,3n | cut -f4-
}
if [[ "${TRANSPORT}" == "publisher" ]]; then
  scenario "__end__"
  for _ in $(seq 100); do
    grep -q -F "${MARKER}"$'\tfalse\t__end__' "${BROKER_OUT}" && break
    sleep 0.1
  done
  grep -q -F "${MARKER}"$'\tfalse\t__end__' "${BROKER_OUT}" \
    || fail "the broker did not receive everything (no end marker)"
  # Label every message with the scenario of the marker before it.
  awk -F'\t' -v m="${MARKER}" -v s="${SYNC_MARKER}" 'BEGIN { OFS = "\t" }
    $1 == m { sc = $3; next }
    $1 == s { next }
    { print sc, $0 }' "${BROKER_OUT}" > "${CAPTURE}"
fi
normalize < "${CAPTURE}" > "${WORK}/actual.tsv"

if [[ "${CONTRACT_UPDATE:-0}" == "1" ]]; then
  cp "${WORK}/actual.tsv" "${EXPECTED}"
  echo "UPDATED: ${EXPECTED} ($(wc -l < "${CAPTURE}") publishes) - review with git diff"
  exit 0
fi
[[ -f "${EXPECTED}" ]] || fail "missing ${EXPECTED} (run with CONTRACT_UPDATE=1 to record)"

if ! cmp -s <(tr -d '\r' < "${EXPECTED}") "${WORK}/actual.tsv"; then
  diff -u <(tr -d '\r' < "${EXPECTED}") "${WORK}/actual.tsv" | head -n 60 >&2 || true
  fail "published topics/payloads differ from ${EXPECTED#"${ROOT_DIR}/"}"
fi
summary="$(cut -f1 "${CAPTURE}" | uniq -c | awk '{printf "%s%s=%s", (NR>1?" ":""), $2, $1}')"
echo "PASS: publish contract holds via ${TRANSPORT} - $(wc -l < "${CAPTURE}") publishes (${summary})"
