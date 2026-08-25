#!/usr/bin/env bash
# Regression test: per-board meter coverage published as an HA sensor.
#
# The number this guards is the one the project actually reasons with - distinct
# meters heard per board. It used to exist only in a session-scoped TSV, so every
# add-on restart destroyed it while much less interesting frame counters kept
# permanent history. These assertions pin down the counting rule (DISTINCT per
# board, not row count) and the discovery contract HA needs for the value to
# reach long-term statistics.
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
[[ "${SCRIPT_DIR}" == "${SCRIPT_PATH}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB="${ROOT_DIR}/rootfs/usr/bin/bridge-lib/09-discovery.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# ── stubs ───────────────────────────────────────────────────────────────────
PUBLISHED="${TMP}/published.txt"
: > "${PUBLISHED}"
mqtt_pub() { printf '%s\t%s\n' "$1" "$2" >> "${PUBLISHED}"; return 0; }
epoch_now() { echo "${FAKE_NOW:-1000000}"; }
log() { :; }
warn() { :; }

DISCOVERY_ENABLED=true
DISCOVERY_PREFIX="homeassistant"
DISCOVERY_RETAIN="true"
STATE_PREFIX="wmbusmeters"
STATUS_ESP_RX_RECEPTION_FILE="${TMP}/reception.tsv"

# Source the function under test. The path is given to shellcheck as well as
# to bash: with -x it follows the directive and can then see that the
# variables set above are consumed inside publish_esp_coverage, instead of
# reporting them as unused.
# shellcheck source=rootfs/usr/bin/bridge-lib/09-discovery.sh
source "${LIB}"

# ── fixture ─────────────────────────────────────────────────────────────────
# lilygo hears 3 distinct meters (one of them twice on different rows - the
# upsert can legitimately produce that after a boot change), heltec hears 2,
# and one meter is heard by nobody else. Distinct total across boards = 4.
cat > "${STATUS_ESP_RX_RECEPTION_FILE}" <<'EOF'
03528107	lilygo	100	200	10	wmbus/lilygo/rx
03534113	lilygo	100	200	20	wmbus/lilygo/rx
41551838	lilygo	100	200	5	wmbus/lilygo/rx
03528107	heltec	100	200	7	wmbus/heltec/rx
03534113	heltec	100	200	3	wmbus/heltec/rx
EOF

FAKE_NOW=1000000
ESP_COVERAGE_LAST_S=0
publish_esp_coverage || fail "publish_esp_coverage returned non-zero"

state_of() {
  awk -F '\t' -v t="wmbusmeters/bridge/coverage/$1/state" '$1==t {v=$2} END{print v}' "${PUBLISHED}"
}
attrs_of() {
  awk -F '\t' -v t="wmbusmeters/bridge/coverage/$1/attrs" '$1==t {v=$2} END{print v}' "${PUBLISHED}"
}

[[ "$(state_of lilygo)" == "3" ]] \
  || fail "lilygo should report 3 distinct meters, got '$(state_of lilygo)'"
[[ "$(state_of heltec)" == "2" ]] \
  || fail "heltec should report 2 distinct meters, got '$(state_of heltec)'"

# The denominator is every meter ANY board heard - that is what makes the
# percentage answer "how much of what is out there does this board get?".
total="$(attrs_of lilygo | jq -r '.meters_total_all_boards')"
[[ "${total}" == "3" ]] || fail "total distinct meters should be 3, got '${total}'"
pct="$(attrs_of lilygo | jq -r '.coverage_pct')"
[[ "${pct}" == "100" ]] || fail "lilygo covers all 3, expected 100, got '${pct}'"
pct="$(attrs_of heltec | jq -r '.coverage_pct')"
[[ "${pct}" == "66.6" ]] || fail "heltec covers 2 of 3, expected 66.6, got '${pct}'"

frames="$(attrs_of lilygo | jq -r '.frames')"
[[ "${frames}" == "35" ]] || fail "lilygo frames should sum to 35, got '${frames}'"

# state_class is the whole point: without it HA keeps no long-term statistics,
# and the number would again survive only until the next restart.
cfg="$(awk -F '\t' '$1=="homeassistant/sensor/wmbus_lilygo_meters_heard/config" {v=$2} END{print v}' "${PUBLISHED}")"
[[ -n "${cfg}" ]] || fail "no discovery config published for lilygo"
[[ "$(jq -r '.state_class' <<< "${cfg}")" == "measurement" ]] \
  || fail "discovery config must set state_class=measurement"
[[ "$(jq -r '.unique_id' <<< "${cfg}")" == "wmbus_lilygo_meters_heard" ]] \
  || fail "unexpected unique_id"

# ── throttling ──────────────────────────────────────────────────────────────
# A second call in the same minute must publish nothing: the heartbeat ticker
# calls this every few seconds and the table is reread in full each time.
before="$(wc -l < "${PUBLISHED}")"
publish_esp_coverage || fail "second call returned non-zero"
[[ "$(wc -l < "${PUBLISHED}")" -eq "${before}" ]] \
  || fail "second call within the interval published anyway"

# After the interval it publishes again - but the discovery config is cached,
# so only state and attributes should be resent.
FAKE_NOW=$((1000000 + 61))
publish_esp_coverage || fail "third call returned non-zero"
added=$(( $(wc -l < "${PUBLISHED}") - before ))
[[ "${added}" -eq 4 ]] \
  || fail "expected 4 new publishes (state+attrs for 2 boards), got ${added}"
grep -c 'homeassistant/sensor/wmbus_lilygo_meters_heard/config' "${PUBLISHED}" | grep -qx 1 \
  || fail "discovery config was republished instead of being cached"

# ── hostile source name ─────────────────────────────────────────────────────
# The board name arrives from an MQTT topic segment, so a malicious publisher
# must not be able to steer our config topic somewhere else.
printf '03528107\t../evil\t100\t200\t1\twmbus/x/rx\n' >> "${STATUS_ESP_RX_RECEPTION_FILE}"
FAKE_NOW=$((1000000 + 200))
publish_esp_coverage || fail "call with hostile source returned non-zero"
grep -q 'evil' "${PUBLISHED}" && fail "a source name with path characters reached a topic"

echo "PASS: per-board coverage sensor counts distinct meters, throttles, and validates source names"
