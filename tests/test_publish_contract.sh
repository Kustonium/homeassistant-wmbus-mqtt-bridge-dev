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
# The real bridge-lib code runs. Only its edges are replaced: mqtt_pub records
# instead of publishing, the clock is fixed, the reception statistics behind
# expire_after are fixed, and the decoder's field catalog comes from
# fixtures/publish_contract/listfields/ (recorded from the pinned binary by
# gen_corpus.sh).
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
trap 'rm -rf "${WORK}"' EXIT
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
mqtt_pub() {
  local retain="false"
  [[ "${3:-false}" == "true" ]] && retain="true"
  printf '%s\t%s\t%s\t%s\n' "${SCENARIO}" "$1" "${retain}" "$2" >> "${CAPTURE}"
  return 0
}
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
SCENARIO="first"; reset_caches
publish_all

# The same telegrams again: configs are cached, only states go out.
SCENARIO="repeat"
publish_all

# The meter's average interval grows: expire_after changes, configs are resent.
SCENARIO="expire_after"; SEEN_AVG=2400
publish_decoded_json "$(line_for 04913581)"
SEEN_AVG=0

# Disabled Discovery: states only.
SCENARIO="discovery_off"; reset_caches; DISCOVERY_ENABLED="false"
publish_decoded_json "$(line_for 03314055)"
DISCOVERY_ENABLED="true"

# Retained states and non-retained configs (both options flipped).
SCENARIO="retain_flipped"; reset_caches; STATE_RETAIN="true"; DISCOVERY_RETAIN="false"
publish_decoded_json "$(line_for 03314055)"
STATE_RETAIN="false"; DISCOVERY_RETAIN="true"

# A required timestamp: the telegram without one is not published at all.
SCENARIO="require_timestamp"; reset_caches; REQUIRE_TIMESTAMP="true"
publish_decoded_json "$(line_for 11111111)"
publish_decoded_json "$(line_for 03314055)"
REQUIRE_TIMESTAMP="false"

# Per-board RSSI joined on: two fresh boards, one stale, one other meter.
SCENARIO="rssi"; reset_caches
{
  printf '%s\t%s\t%s\t%s\n' 21031894 -72 lilygo "$(( FAKE_NOW - 10 ))"
  printf '%s\t%s\t%s\t%s\n' 21031894 -65 xiao-seed "$(( FAKE_NOW - 20 ))"
  printf '%s\t%s\t%s\t%s\n' 21031894 -80 heltec "$(( FAKE_NOW - RSSI_MAX_AGE_S - 1 ))"
  printf '%s\t%s\t%s\t%s\n' 03314055 -90 lilygo "$(( FAKE_NOW - 10 ))"
} > "${STATUS_RSSI_FILE}"
publish_decoded_json "$(line_for 21031894)"
publish_decoded_json "$(line_for 21031894)"

# Fields excluded per meter (globs, case-insensitive, "status" takes the pair).
SCENARIO="exclude"; reset_caches
METER_EXCLUDE_FIELDS["21031894"]="consumption_at_history_* HISTORY_*_DATE"
METER_EXCLUDE_FIELDS["0abcdbee"]="status target_*"
publish_decoded_json "$(line_for 21031894)"
publish_decoded_json "$(line_for 0abcdbee)"
publish_decoded_json "$(line_for 21031894)"

# A SEARCH temporary meter: its entities are cleared, never created.
SCENARIO="search_temp"; reset_caches; SEARCH_MODE="true"
search_line="$(line_for 0abcdbee | jq -c '.name = "search_0abcdbee"')"
is_search_temp_json "${search_line}" && clear_search_discovery_from_json "${search_line}"
clear_search_discovery_from_json "${search_line}"   # cached: nothing more
SEARCH_MODE="false"

# Factory reset of one meter: every retained config the broker reports.
SCENARIO="clear_meter"; reset_caches
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
  FAKE_NOW=$(( t0 + $1 )); SCENARIO="coverage@$1"
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
SCENARIO="canary"; reset_caches; VERIFY_HA_ENTITIES="true"
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
echo "PASS: publish contract holds - $(wc -l < "${CAPTURE}") publishes (${summary})"
