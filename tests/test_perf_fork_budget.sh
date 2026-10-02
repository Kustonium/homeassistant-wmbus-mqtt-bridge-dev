#!/usr/bin/env bash
# Performance regression test: process (fork) budget per telegram.
#
# Every RAW telegram from every ESP runs status_raw_seen and the per-ESP
# tracker, every /rx and rssi/<id> message runs its subscriber, every
# transmission heard by the parallel LISTEN instance runs its block handler, and
# every decoded telegram runs status_meter_seen, inject_rssi_into_json and
# emit_discovery_from_json. On a 5-ESP site with ~210 meters on air (~3 RAW
# telegrams/s) these bash paths used ~200% CPU, almost all of it spent
# starting processes - e.g. two subshells per meter-preview-<id> file per RAW
# telegram (ee7a849). Nothing failed when that happened, so this test counts
# the processes instead.
#
# The cost has two independent dimensions:
#   - boards: every ESP delivers its own copy, so the number of calls grows with
#     the number of boards (deduplication only happens inside wmbusmeters);
#   - meters on air: candidate rows and preview files grow with it, and must
#     NOT raise the cost of a single call.
# The test therefore measures the cost of ONE call at 10/50/200 meters on air
# (one board) and fails when it grows with the meter count or exceeds an
# absolute budget. Multiplying by boards x telegram rate is a property of the
# installation, not of this code.
#
# Forks are read from the `processes` counter in /proc/stat (forks since boot,
# system wide). Other processes on the machine can only ADD to a sample, so
# each measurement is the minimum over several repeats from an identical state.
#
# The globals below are read by the bridge-lib/*.sh sourced in a loop, which
# the linter cannot follow; hence the file-wide disable of SC2034 and SC2153.
# shellcheck disable=SC2034,SC2153
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
[[ "${SCRIPT_DIR}" == "${SCRIPT_PATH}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BRIDGE_SH="${ROOT_DIR}/rootfs/usr/bin/bridge.sh"
LIB_DIR="${ROOT_DIR}/rootfs/usr/bin/bridge-lib"
FIXTURE_DIR="${ROOT_DIR}/tests/fixtures/qwaterv2"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -r /proc/stat ]] || { echo "SKIP: /proc/stat not available"; exit 0; }
for _bin in jq flock awk; do
  command -v "${_bin}" >/dev/null 2>&1 || fail "missing ${_bin}"
done

# ── budgets ─────────────────────────────────────────────────────────────────
# Absolute budgets: forks for ONE call, about 25% above the cost measured on
# 2026-10-02 (bash 5.2; the number in the comment). A fork is every new
# process, including a $(...) subshell that runs a shell function and execs
# nothing. Raise a budget only together with an explanation in the commit that
# added the processes.
BUDGET_RAW_NO_PREVIEW=38       # 30: RAW telegram of a meter without a preview file
BUDGET_RAW_PREVIEW=43          # 34: RAW telegram of a candidate with a preview file
BUDGET_METER_SEEN=49           # 39: status_meter_seen
BUDGET_INJECT_RSSI=8           #  6: line="$(inject_rssi_into_json ...)"
BUDGET_DISCOVERY=12            #  9: emit_discovery_from_json, discovery cache full
BUDGET_JSON_TOTAL=68           # 54: sum of the three decoded-telegram steps
BUDGET_ESP_TRACKER=17          # 13: per-ESP tracker, one /telegram message
BUDGET_ESP_RX=42               # 33: /rx subscriber, one message
BUDGET_ESP_RSSI=9              #  7: rssi/<id> subscriber, configured meter
                               #     (bash handler, the WMBUS_LEDGER=bash fallback)
# Paths booked by bridge_ledger.py: forks for a whole batch of LEDGER_BATCH
# messages through one process. Starting python3 is the only fork; per
# message the cost must stay zero.
BUDGET_LEDGER_RSSI=2           #  1: rssi/<id>, LEDGER_BATCH messages
LEDGER_BATCH=200
BUDGET_LISTEN_BLOCK=74         # 59: LISTEN block of a known candidate
# How much ONE call may cost more at 200 meters on air than at 10.
SCALE_TOLERANCE=2
METER_COUNTS=(10 50 200)
REPEATS=5

# ── fixture: one realistic telegram (Qundis qwaterv2, id 52632878) ──────────
RAW_HEX="$(tr -d '[:space:]' < "${FIXTURE_DIR}/52632878.hex")"
JSON_LINE="$(jq -c '. + {timestamp: "2026-10-02T10:00:00Z"}' "${FIXTURE_DIR}/52632878.golden.json")"
METER_ID="52632878"
# Same frame with the A-field of a meter (77665544) that has no preview file:
# the preview scan then visits every file and matches none.
RAW_HEX_OTHER="${RAW_HEX:0:8}44556677${RAW_HEX:16}"
# A candidate that is not a configured meter: the first id fixture_ids makes.
CANDIDATE_ID="10001003"

TMP="$(mktemp -d)"
PERF_CURRENT=""
cleanup() {
  local rc=$?
  if (( rc != 0 )) && [[ -n "${PERF_CURRENT}" ]]; then
    echo "FAIL: '${PERF_CURRENT}' failed (rc=${rc}): fixture, stub or function missing" >&2
  fi
  wait 2>/dev/null || true
  rm -rf "${TMP}"
}
trap cleanup EXIT

# ── environment of the bridge ───────────────────────────────────────────────
BASE="${TMP}/data"
mkdir -p "${BASE}"
# The file paths are the ones bridge.sh defines from ${BASE} (and from paths
# derived from it). Only plain "VAR=\"${X}/literal\"" assignments are taken,
# so evaluating them cannot run anything.
while IFS= read -r _assign; do
  _src="${_assign#*=\"\$\{}"
  _src="${_src%%\}*}"
  [[ -n "${!_src+x}" ]] || continue
  eval "${_assign}"
done < <(grep -E '^[A-Z_][A-Z0-9_]*="\$\{[A-Z_][A-Z0-9_]*\}[^"$`]*"$' "${BRIDGE_SH}")
for _v in STATUS_CANDIDATES_FILE STATUS_RECENT_RAW_FILE STATUS_RSSI_FILE \
          STATUS_SEEN_FILE STATUS_METERS_FILE PREVIEW_METER_DIR METER_DIR \
          STATUS_JSON STATUS_RAW_COUNT_FILE STATUS_DISCOVERY_FLAG; do
  [[ -n "${!_v:-}" && "${!_v}" == "${BASE}/"* ]] || fail "bridge.sh no longer defines ${_v} from \${BASE}"
done

LOGLEVEL="normal"
RAW_TOPIC="wmbus/+/telegram"
STATE_PREFIX="wmbusmeters"
DISCOVERY_PREFIX="homeassistant"
DISCOVERY_ENABLED="true"
DISCOVERY_RETAIN="true"
SEARCH_MODE="false"
MQTT_HOST="localhost"
MQTT_PORT="1883"
# Never start a real decoder from the field-catalog loader.
WMBUSMETERS_BIN="/bin/false"

for _lib in "${LIB_DIR}"/*.sh; do
  # shellcheck disable=SC1090
  source "${_lib}"
done

# ── stubs: no broker, no log output ─────────────────────────────────────────
PERF_PUBS=0
mqtt_pub() { PERF_PUBS=$((PERF_PUBS + 1)); return 0; }
log() { :; }
warn() { :; }

# Globals bridge.sh initialises before the pipelines start.
STATUS_MQTT_CONNECTED="true"
STATUS_WMBUSMETERS_RUNNING="true"
STATUS_RAW_COUNT=0
STATUS_DECODED_COUNT=0
STATUS_DISCOVERY_PUBLISHED="false"
STATUS_DISCOVERY_PUBLISHED_AT=""
STATUS_LAST_RAW_SEEN=""
STATUS_LAST_DECODED_SEEN=""
STATUS_LAST_ERROR=""
STATUS_LAST_EVENT="running"
RAW_RATE_CUR_MIN_EPOCH=0
RAW_RATE_CUR_MIN_COUNT=0
RAW_RATE_PREV_MIN_COUNT=0

# ── fork counter ────────────────────────────────────────────────────────────
# Reads /proc/stat with the read builtin: the counter itself costs no fork.
_proc_forks() {
  local key val
  while read -r key val _; do
    if [[ "${key}" == "processes" ]]; then
      REPLY="${val}"
      return 0
    fi
  done < /proc/stat
  fail "no 'processes' line in /proc/stat"
}

# measure <prepare function> <command...>
# Runs prepare (not counted) and then the command (counted) REPEATS times and
# sets MEASURED to the smallest fork count seen.
measure() {
  local prepare="$1" before n best=""
  shift
  for (( n = 0; n < REPEATS; n++ )); do
    "${prepare}"
    _proc_forks; before="${REPLY}"
    # Called bare, as the bridge calls it, so set -e applies inside exactly as
    # in production; if it fails, the EXIT trap names it.
    PERF_CURRENT="$*"
    "$@" >/dev/null 2>&1
    PERF_CURRENT=""
    _proc_forks
    (( REPLY - before >= 0 )) || fail "fork counter went backwards"
    if [[ -z "${best}" ]] || (( REPLY - before < best )); then
      best=$(( REPLY - before ))
    fi
  done
  MEASURED="${best}"
}

# ── fixture with M meters on air ────────────────────────────────────────────
# Ids sort before 52632878, so the preview scan visits every other file before
# it reaches the matching one. None of their little-endian forms occurs in
# either frame.
fixture_ids() {
  local m="$1" i id le
  for (( i = 1; i < m; i++ )); do
    printf -v id '%08X' $(( 0x10000000 + i * 4099 ))
    le="${id:6:2}${id:4:2}${id:2:2}${id:0:2}"
    if [[ "${RAW_HEX,,}" == *"${le,,}"* || "${RAW_HEX_OTHER,,}" == *"${le,,}"* ]]; then
      continue
    fi
    printf '%s\n' "${id}"
  done
  printf '%s\n' "${METER_ID}"
}

build_fixture() {
  local m="$1" id now iso n
  now="$(date +%s)"
  iso="$(date -Iseconds)"
  rm -rf "${BASE}"
  mkdir -p "${BASE}" "${METER_DIR}" "${PREVIEW_METER_DIR}" \
    "${BASE}/.preview_attempts" "${BASE}/.preview_decode_locks" \
    "${BASE}/.preview_decode_last" "${BASE}/.preview_decode_slots"
  : > "${STATUS_CANDIDATES_FILE}"
  : > "${STATUS_RSSI_FILE}"
  : > "${STATUS_SEEN_FILE}"
  : > "${STATUS_METERS_FILE}"
  : > "${STATUS_METER_LAST_JSON_FILE}"
  : > "${STATUS_METER_KEY_PROBLEM_FILE}"
  : > "${STATUS_EVENTS_FILE}"
  : > "${STATUS_RATE_HISTORY_FILE}"
  : > "${STATUS_BROKER_ERROR_FILE}"

  while IFS= read -r id; do
    # Candidate row with the manufacturer already known: steady state.
    printf '%s\tqwaterv2\tWater meter (0x07)\t%s\t42\t30\t5\t20\t(QDS) Qundis\n' \
      "${id}" "${iso}" >> "${STATUS_CANDIDATES_FILE}"
    # Exactly what ensure_candidate_autodecode writes for this row, so a
    # LISTEN block finds the preview unchanged: the steady state.
    printf 'name=preview_%s\nid=%s\ndriver=qwaterv2\n' "${id}" "${id,,}" \
      > "${PREVIEW_METER_DIR}/meter-preview-${id}"
    printf '%s\t-%d\tlilygo\t%d\n' "${id}" $(( 60 + ${#id} )) "${now}" >> "${STATUS_RSSI_FILE}"
    for (( n = 20; n > 0; n-- )); do
      printf '%s\tcandidate\t%d\n' "${id}" $(( now - n * 30 )) >> "${STATUS_SEEN_FILE}"
    done
  done < <(fixture_ids "${m}")

  # The decoded meter is configured, so it also has history as a meter.
  printf 'name=water\nid=%s\ndriver=qwaterv2\n' "${METER_ID,,}" > "${METER_DIR}/meter-0001"
  for (( n = 20; n > 0; n-- )); do
    printf '%s\tmeter\t%d\n' "${METER_ID}" $(( now - n * 30 )) >> "${STATUS_SEEN_FILE}"
  done
  printf '%s\twater\tqwaterv2\twater\ttotal_m3\t9.001\t%s\tpublished\t20\t30\t5\t20\t\n' \
    "${METER_ID}" "${iso}" > "${STATUS_METERS_FILE}"

  # Full recent-RAW ring (200 rows, the size status_store_recent_raw keeps).
  : > "${STATUS_RECENT_RAW_FILE}"
  for (( n = 0; n < 200; n++ )); do
    printf '%s\t%s\t%s\n' "${iso}" "${#RAW_HEX}" "${RAW_HEX}" >> "${STATUS_RECENT_RAW_FILE}"
  done

  printf '1000\n' > "${STATUS_RAW_COUNT_FILE}"
  printf '%s\n' "${iso}" > "${STATUS_LAST_RAW_FILE}"
  printf '%s\n' "${iso}" > "${STATUS_DISCOVERY_FLAG}"
  printf '1\n' > "${STATUS_OFFICIAL_METERS_COUNT_FILE}"
  # The preview one-shot of the candidate already ran: it is throttled, as on
  # a running system between two decodes. A time in the future keeps it
  # throttled however long the test takes.
  printf '%s\n' $(( now + 86400 )) > "${BASE}/.preview_decode_last/${METER_ID}"
  printf '%s\n' $(( now + 86400 )) > "${BASE}/.preview_decode_last/${CANDIDATE_ID}"
  # ESP subscriber state, and the candidate already announced once.
  : > "${STATUS_ESP_TELEGRAM_DEVICES_FILE}"
  : > "${STATUS_ESP_METER_DEVICE_FILE}"
  : > "${STATUS_ESP_METER_RECEPTION_FILE}"
  : > "${ESP_RX_HISTORY_FILE}"
  : > "${STATUS_ESP_RX_RECEPTION_FILE}"
  : > "${STATUS_ESP_RX_MODE_FILE}"
  : > "${ESP_RF_RX_HISTORY_FILE}"
  : > "${STATUS_ESP_RX_SEQUENCE_FILE}"
  : > "${STATUS_ESP_RX_BOOTS_FILE}"
  : > "${STATUS_ESP_RX_CLOCK_FILE}"
  : > "${STATUS_CANDIDATE_ANALYSIS_FILE}"
  : > "${STATUS_CANDIDATE_RAW_FILE}"
  : > "${STATUS_CANDIDATE_PREVIEW_STATE_FILE}"
  printf '%s\n' "${CANDIDATE_ID}" > "${SNIPPET_STATE}"

  rm -rf "${TMP}/snapshot"
  cp -a "${BASE}" "${TMP}/snapshot"
}

restore_state() {
  rm -rf "${BASE}"
  cp -a "${TMP}/snapshot" "${BASE}"
  # Same minute as the previous telegram and not a 25th telegram: the common
  # case, without the once-per-minute / once-per-25 bookkeeping.
  RAW_RATE_CUR_MIN_EPOCH=$(( $(date +%s) / 60 ))
  RAW_RATE_CUR_MIN_COUNT=3
}

# Decoded-telegram steps, called the way bridge.sh calls them.
run_meter_seen() { status_meter_seen "${JSON_LINE}"; }
run_inject_rssi() { PERF_LINE="$(inject_rssi_into_json "${METER_ID}" "${JSON_LINE}")"; }
run_discovery() { emit_discovery_from_json "${PERF_LINE}"; }

# Per-message handlers of the background subscribers and of LISTEN, with the
# state their loops keep. The tracker has already attributed the meter to this
# board (steady state: no meter-device rewrite).
_RT_DEV_POS=1
declare -A _MD_LAST=()
_rx_history_since_trim=0
_rx_meta_since_trim=0
declare -A _RSSI_WANTED=()
_rssi_wanted_at=0
SEARCH_MODE="false"
SEARCH_EXPECTED_VALUE_M3="0"
RX_PAYLOAD='{"schema":1,"boot_id":"A84F12C7","seq":7,"rx_task_wakeup_us":123456,"meter_id":"52632878","mode":"T1","rssi_dbm":-54,"frame_crc32":"7F56A83C","frame_length":123,"received_at":"2026-10-02T10:00:00.123Z"}'
run_tracker() { _MD_LAST["${METER_ID}"]="lilygo"; _esp_tracker_handle_message "wmbus/lilygo/telegram" "${RAW_HEX}"; }
run_rx() { _esp_rx_handle_message "wmbus/lilygo/rx" "${RX_PAYLOAD}"; }
run_rssi() { _esp_rssi_handle_message "wmbus/lilygo/rssi/${METER_ID}" "-70"; }
run_listen() { _process_listen_text_block "${CANDIDATE_ID}" "qwaterv2" "Water meter (0x07)" "(QDS) Qundis"; }
BRIDGE_LEDGER="${ROOT_DIR}/rootfs/usr/bin/bridge_ledger.py"
for (( n = 1; n <= LEDGER_BATCH; n++ )); do
  printf 'wmbus/board%d/rssi/%s\t-%d\n' $(( n % 5 )) "${METER_ID}" $(( 50 + n % 40 ))
done > "${TMP}/rssi_batch"
run_ledger_rssi() {
  python3 "${BRIDGE_LEDGER}" rssi --meter-dir "${METER_DIR}" --rssi-file "${STATUS_RSSI_FILE}" \
    < "${TMP}/rssi_batch"
}

check_raw_effect() {
  [[ "$(cat "${STATUS_RAW_COUNT_FILE}")" == "1001" ]] \
    || fail "status_raw_seen did not count the telegram (fixture or stub broken)"
  jq -e '.pipeline.raw_count == 1001' "${STATUS_JSON}" >/dev/null \
    || fail "status_raw_seen did not write status.json (fixture or stub broken)"
}

# ── run the matrix ──────────────────────────────────────────────────────────
declare -A R
# Discovery steady state: the cache is in memory and survives the restores, so
# fill it once with the same telegram and the same seen-history.
build_fixture "${METER_COUNTS[0]}"
restore_state
run_inject_rssi
[[ "${PERF_LINE}" == *'"rssi_lilygo_dbm":'* ]] || fail "inject_rssi_into_json did not join the RSSI (fixture broken)"
PERF_PUBS=0
emit_discovery_from_json "${PERF_LINE}" >/dev/null 2>&1
(( PERF_PUBS > 0 )) || fail "emit_discovery_from_json published nothing on first sight (fixture or stub broken)"

for m in "${METER_COUNTS[@]}"; do
  build_fixture "${m}"

  measure restore_state status_raw_seen "${RAW_HEX_OTHER}"
  R[raw_no_preview,${m}]="${MEASURED}"
  check_raw_effect

  measure restore_state status_raw_seen "${RAW_HEX}"
  R[raw_preview,${m}]="${MEASURED}"
  check_raw_effect

  measure restore_state run_meter_seen
  R[meter_seen,${m}]="${MEASURED}"
  [[ "$(awk -F '\t' -v id="${METER_ID}" '$1==id {print $5 "=" $6}' "${STATUS_METERS_FILE}")" == "total_m3=9.002" ]] \
    || fail "status_meter_seen did not store the reading (fixture broken)"

  measure restore_state run_inject_rssi
  R[inject_rssi,${m}]="${MEASURED}"

  PERF_PUBS=0
  measure restore_state run_discovery
  R[discovery,${m}]="${MEASURED}"
  (( PERF_PUBS == 0 )) \
    || fail "emit_discovery_from_json republished ${PERF_PUBS} configs at M=${m}: not the steady state the budget is for"

  R[json_total,${m}]=$(( R[meter_seen,${m}] + R[inject_rssi,${m}] + R[discovery,${m}] ))

  measure restore_state run_tracker
  R[esp_tracker,${m}]="${MEASURED}"
  [[ "$(awk -F '\t' '$1=="lilygo" {print $4}' "${STATUS_ESP_TELEGRAM_DEVICES_FILE}")" == "1" ]] \
    || fail "tracker did not count the telegram for its board (fixture broken)"
  [[ -s "${ESP_RX_HISTORY_FILE}" ]] || fail "tracker did not append reception history (fixture broken)"

  measure restore_state run_rx
  R[esp_rx,${m}]="${MEASURED}"
  [[ "$(awk -F '\t' '$1=="lilygo" {print $2 "/" $3}' "${STATUS_ESP_RX_SEQUENCE_FILE}")" == "A84F12C7/7" ]] \
    || fail "/rx handler did not record the sequence (fixture broken)"

  measure restore_state run_rssi
  R[esp_rssi,${m}]="${MEASURED}"
  [[ "$(awk -F '\t' -v id="${METER_ID}" '$1==id && $3=="lilygo" {print $2}' "${STATUS_RSSI_FILE}")" == "-70" ]] \
    || fail "rssi handler did not store the reading (fixture broken)"

  measure restore_state run_ledger_rssi
  R[ledger_rssi,${m}]="${MEASURED}"
  [[ "$(awk -F '\t' -v id="${METER_ID}" '$1==id && $3 ~ /^board[0-4]$/' "${STATUS_RSSI_FILE}" | wc -l)" == "5" ]] \
    || fail "bridge_ledger.py rssi did not store one row per board (fixture broken)"

  measure restore_state run_listen
  R[listen_block,${m}]="${MEASURED}"
  [[ "$(awk -F '\t' -v id="${CANDIDATE_ID}" '$1==id && $2=="candidate"' "${STATUS_SEEN_FILE}" | wc -l)" == "21" ]] \
    || fail "LISTEN block did not record the candidate reception (fixture broken)"
  [[ ! -s "${STATUS_CANDIDATE_PREVIEW_STATE_FILE}" && -z "$(ls -A "${BASE}/.preview_decode_locks")" ]] \
    || fail "LISTEN block rewrote the preview or started a one-shot: not the steady state the budget is for"
done

# ── report and verdict ──────────────────────────────────────────────────────
STEPS=(raw_no_preview raw_preview meter_seen inject_rssi discovery json_total
       esp_tracker esp_rx esp_rssi listen_block ledger_rssi)
declare -A LABEL=(
  [raw_no_preview]="status_raw_seen (no preview match)"
  [raw_preview]="status_raw_seen (preview match)"
  [meter_seen]="status_meter_seen"
  [inject_rssi]="inject_rssi_into_json"
  [discovery]="emit_discovery_from_json"
  [json_total]="decoded JSON path (sum)"
  [esp_tracker]="ESP tracker (/telegram)"
  [esp_rx]="ESP /rx subscriber"
  [esp_rssi]="ESP rssi subscriber (bash fallback)"
  [listen_block]="LISTEN block (known candidate)"
  [ledger_rssi]="ledger rssi, ${LEDGER_BATCH} msgs, 1 process"
)
declare -A BUDGET=(
  [raw_no_preview]="${BUDGET_RAW_NO_PREVIEW}"
  [raw_preview]="${BUDGET_RAW_PREVIEW}"
  [meter_seen]="${BUDGET_METER_SEEN}"
  [inject_rssi]="${BUDGET_INJECT_RSSI}"
  [discovery]="${BUDGET_DISCOVERY}"
  [json_total]="${BUDGET_JSON_TOTAL}"
  [esp_tracker]="${BUDGET_ESP_TRACKER}"
  [esp_rx]="${BUDGET_ESP_RX}"
  [esp_rssi]="${BUDGET_ESP_RSSI}"
  [listen_block]="${BUDGET_LISTEN_BLOCK}"
  [ledger_rssi]="${BUDGET_LEDGER_RSSI}"
)

printf '%-38s' "forks per call, meters on air ->"
for m in "${METER_COUNTS[@]}"; do printf '%6s' "${m}"; done
printf '%9s\n' "budget"
failures=()
first="${METER_COUNTS[0]}"
last="${METER_COUNTS[${#METER_COUNTS[@]}-1]}"
for s in "${STEPS[@]}"; do
  printf '%-38s' "${LABEL[${s}]}"
  for m in "${METER_COUNTS[@]}"; do
    printf '%6s' "${R[${s},${m}]}"
    if (( R[${s},${m}] > BUDGET[${s}] )); then
      failures+=("${LABEL[${s}]}: ${R[${s},${m}]} forks per call at ${m} meters on air, budget ${BUDGET[${s}]}")
    fi
  done
  printf '%9s\n' "${BUDGET[${s}]}"
  if (( R[${s},${last}] - R[${s},${first}] > SCALE_TOLERANCE )); then
    failures+=("${LABEL[${s}]}: cost grows with meters on air - ${R[${s},${first}]} forks at ${first}, ${R[${s},${last}]} at ${last} (tolerance ${SCALE_TOLERANCE}); something now runs a process per meter/preview file/candidate row")
  fi
done

if (( ${#failures[@]} > 0 )); then
  for f in "${failures[@]}"; do echo "FAIL: ${f}" >&2; done
  exit 1
fi
echo "OK: fork budget per telegram holds and does not grow with meters on air"
