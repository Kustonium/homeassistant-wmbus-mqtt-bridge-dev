#!/usr/bin/env bash
# Performance regression test: process (fork) budget per telegram.
#
# Every RAW telegram from every ESP runs the RAW counter and the per-ESP
# tracker, every /rx and rssi/<id> message runs its subscriber, every telegram
# heard by the parallel LISTEN instance runs its parser, and every decoded
# telegram runs status_meter_seen, inject_rssi_into_json and
# emit_discovery_from_json. On a 5-ESP site with ~210 meters on air (~3 RAW
# telegrams/s) these paths used ~200% CPU when they were bash, almost all of it
# spent starting processes - e.g. two subshells per meter-preview-<id> file per
# RAW telegram (ee7a849). Nothing failed when that happened, so this test
# counts the processes instead. The per-message paths now run in
# bridge_ledger.py (a batch costs the forks of starting it, none per message);
# the decoded-telegram steps are still bash, measured per call.
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
BUDGET_METER_SEEN=49           # 39: status_meter_seen
BUDGET_INJECT_RSSI=8           #  6: line="$(inject_rssi_into_json ...)"
BUDGET_DISCOVERY=12            #  9: emit_discovery_from_json, discovery cache full
BUDGET_JSON_TOTAL=68           # 54: sum of the three decoded-telegram steps
# Paths booked by bridge_ledger.py: forks for a whole batch of LEDGER_BATCH
# messages through one process. Starting python3 is the only fork; per
# message the cost must stay zero.
BUDGET_LEDGER_RSSI=2           #  1: rssi/<id>, LEDGER_BATCH messages
BUDGET_LEDGER_RX=2             #  1: /rx, LEDGER_BATCH messages
BUDGET_LEDGER_TRACKER=2        #  1: /telegram tracker, LEDGER_BATCH messages
# The RAW counter stage: python3 plus the bash loop that takes its hand-overs
# (subshells of the stage pipeline). Telegrams of a candidate whose preview is
# throttled, so nothing is handed over.
BUDGET_LEDGER_RAW=6            #  4: _raw_counter_stage, LEDGER_BATCH telegrams
# Diehl/SAP (0x304C) telegrams of candidates bash would register exactly as
# they are: one already classified (driver izar) and one of device type 01,
# which bash registers as "auto" on every telegram. Python books the reception
# itself; nothing may be handed to bash (each hand-over costs ~50 forks).
BUDGET_LEDGER_SAP=6            #  4: _raw_counter_stage, LEDGER_BATCH SAP telegrams
# The parser of the pure LISTEN instance: LEDGER_BATCH blocks of a known,
# announced candidate; nothing may be handed to bash.
BUDGET_LEDGER_LISTEN=6         #  4: _listen_parse_stage, LEDGER_BATCH blocks
# The same blocks from the main DECODE instance while no meter is configured
# (every new installation): run_once hands its listen output to the same
# parser (_listen_parse_stage zero); nothing may be handed to bash. The
# inline bash parser it replaced cost ~85-90 forks per block.
BUDGET_LEDGER_ZERO=6           #  4: _listen_parse_stage zero, LEDGER_BATCH blocks
# Boards hearing the same air: every telegram arrives once per board, so the
# ledger paths see BOARDS times the messages. Per message they must stay at
# zero forks: a batch from BOARDS boards may cost at most SCALE_TOLERANCE more
# than the same telegrams from one board.
BOARDS=5
AIR_BATCH=40                   # telegrams on air per batch
LEDGER_BATCH=200
# How much ONE call may cost more at 200 meters on air than at 10.
SCALE_TOLERANCE=2
METER_COUNTS=(10 50 200)
REPEATS=5

# ── fixture: one realistic telegram (Qundis qwaterv2, id 52632878) ──────────
RAW_HEX="$(tr -d '[:space:]' < "${FIXTURE_DIR}/52632878.hex")"
JSON_LINE="$(jq -c '. + {timestamp: "2026-10-02T10:00:00Z"}' "${FIXTURE_DIR}/52632878.golden.json")"
METER_ID="52632878"
# A candidate that is not a configured meter: the first id fixture_ids makes.
CANDIDATE_ID="10001003"
# Diehl/SAP IZAR frames (device type 01): one candidate registered as auto with
# the device-type label, one already classified by LISTEN.
SAP_AUTO_HEX="$(tr -d '[:space:]' < "${ROOT_DIR}/tests/fixtures/izar/2156B4C2.hex")"
SAP_AUTO_ID="2156B4C2"
SAP_KNOWN_HEX="$(tr -d '[:space:]' < "${ROOT_DIR}/tests/fixtures/izar/215F908A.hex")"
SAP_KNOWN_ID="215F908A"

TMP="$(mktemp -d)"
PERF_CURRENT=""
# The EXIT trap runs with the redirections of the command that failed, which
# send stderr to /dev/null; report on the test's own stderr.
exec {PERF_STDERR}>&2
cleanup() {
  local rc=$?
  if (( rc != 0 )) && [[ -n "${PERF_CURRENT}" ]]; then
    echo "FAIL: '${PERF_CURRENT}' failed (rc=${rc}): fixture, stub or function missing" >&"${PERF_STDERR}"
  fi
  wait 2>/dev/null || true
  rm -rf "${TMP}"
}
trap cleanup EXIT

# ── environment of the bridge ───────────────────────────────────────────────
BASE="${TMP}/data"
mkdir -p "${BASE}"
# The status files are defined from ${RUNTIME}, the RAM directory in the
# add-on; without a tmpfs it is ${BASE}, as here.
RUNTIME="${BASE}"
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
# any of the test frames.
fixture_ids() {
  local m="$1" i id le
  for (( i = 1; i < m; i++ )); do
    printf -v id '%08X' $(( 0x10000000 + i * 4099 ))
    le="${id:6:2}${id:4:2}${id:2:2}${id:0:2}"
    if [[ "${RAW_HEX,,}${SAP_AUTO_HEX,,}${SAP_KNOWN_HEX,,}" == *"${le,,}"* ]]; then
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

  # The Diehl/SAP candidates, in the state bash leaves them in.
  printf '%s\tauto\tUnknown meter type (0x01)\t%s\t42\t30\t5\t20\t(SAP) Diehl Metering\n' \
    "${SAP_AUTO_ID}" "${iso}" >> "${STATUS_CANDIDATES_FILE}"
  printf 'name=preview_%s\nid=%s\n' "${SAP_AUTO_ID}" "${SAP_AUTO_ID,,}" \
    > "${PREVIEW_METER_DIR}/meter-preview-${SAP_AUTO_ID}"
  printf '%s\tizar\tWater meter (0x07)\t%s\t42\t30\t5\t20\t(SAP) Diehl Metering\n' \
    "${SAP_KNOWN_ID}" "${iso}" >> "${STATUS_CANDIDATES_FILE}"
  for (( n = 20; n > 0; n-- )); do
    printf '%s\tcandidate\t%d\n%s\tcandidate\t%d\n' \
      "${SAP_AUTO_ID}" $(( now - n * 30 )) "${SAP_KNOWN_ID}" $(( now - n * 30 )) >> "${STATUS_SEEN_FILE}"
  done

  # The decoded meter is configured, so it also has history as a meter.
  printf 'name=water\nid=%s\ndriver=qwaterv2\n' "${METER_ID,,}" > "${METER_DIR}/meter-0001"
  for (( n = 20; n > 0; n-- )); do
    printf '%s\tmeter\t%d\n' "${METER_ID}" $(( now - n * 30 )) >> "${STATUS_SEEN_FILE}"
  done
  printf '%s\twater\tqwaterv2\twater\ttotal_m3\t9.001\t%s\tpublished\t20\t30\t5\t20\t\n' \
    "${METER_ID}" "${iso}" > "${STATUS_METERS_FILE}"

  # Full recent-RAW ring (200 rows, the size the RAW counter keeps).
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
  printf '%s\n' $(( now + 86400 )) > "${BASE}/.preview_decode_last/${SAP_AUTO_ID}"
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
}

# Decoded-telegram steps, called the way bridge.sh calls them.
run_meter_seen() { status_meter_seen "${JSON_LINE}"; }
run_inject_rssi() { PERF_LINE="$(inject_rssi_into_json "${METER_ID}" "${JSON_LINE}")"; }
run_discovery() { emit_discovery_from_json "${PERF_LINE}"; }

# The ledger paths, batch by batch, as their subscribers and stages run them.
SEARCH_MODE="false"
SEARCH_EXPECTED_VALUE_M3="0"
BRIDGE_LEDGER="${ROOT_DIR}/rootfs/usr/bin/bridge_ledger.py"
for (( n = 1; n <= LEDGER_BATCH; n++ )); do
  printf 'wmbus/board%d/rssi/%s\t-%d\n' $(( n % 5 )) "${METER_ID}" $(( 50 + n % 40 ))
done > "${TMP}/rssi_batch"
for (( n = 1; n <= LEDGER_BATCH; n++ )); do
  printf 'wmbus/board%d/rx\t{"schema":1,"boot_id":"A84F12C7","seq":%d,"rx_task_wakeup_us":1,"meter_id":"%s","mode":"T1","frame_crc32":"7F56A83C","frame_length":123,"received_at":"2026-10-02T10:00:00.123Z"}\n' \
    $(( n % 5 )) "${n}" "${METER_ID}"
done > "${TMP}/rx_batch"
run_ledger_rx() {
  python3 "${BRIDGE_LEDGER}" rx \
    --reception-file "${STATUS_ESP_RX_RECEPTION_FILE}" --mode-file "${STATUS_ESP_RX_MODE_FILE}" \
    --history-file "${ESP_RF_RX_HISTORY_FILE}" --sequence-file "${STATUS_ESP_RX_SEQUENCE_FILE}" \
    --boots-file "${STATUS_ESP_RX_BOOTS_FILE}" --clock-file "${STATUS_ESP_RX_CLOCK_FILE}" \
    < "${TMP}/rx_batch"
}
for (( n = 1; n <= LEDGER_BATCH; n++ )); do
  printf 'wmbus/board%d/telegram\t%s\n' $(( n % 5 )) "${RAW_HEX}"
done > "${TMP}/tracker_batch"
run_ledger_tracker() {
  python3 "${BRIDGE_LEDGER}" tracker --dev-pos 1 \
    --devices-file "${STATUS_ESP_TELEGRAM_DEVICES_FILE}" --meter-device-file "${STATUS_ESP_METER_DEVICE_FILE}" \
    --reception-file "${STATUS_ESP_METER_RECEPTION_FILE}" --history-file "${ESP_RX_HISTORY_FILE}" \
    < "${TMP}/tracker_batch"
}
for (( n = 1; n <= LEDGER_BATCH; n++ )); do printf '%s\n' "${RAW_HEX}"; done > "${TMP}/raw_batch"
# The pipeline runs with errexit off (bridge.sh: set +e before run_once).
run_ledger_raw() { ( set +e; _raw_counter_stage < "${TMP}/raw_batch" ); }
for (( n = 1; n <= LEDGER_BATCH / 2; n++ )); do printf '%s\n%s\n' "${SAP_AUTO_HEX}" "${SAP_KNOWN_HEX}"; done \
  > "${TMP}/sap_batch"
# The stage's status is that of the last hand-over it ran, and nothing in the
# pipeline reads it; a hand-over must show up in the check below, not abort.
run_ledger_sap() { ( set +e; _raw_counter_stage < "${TMP}/sap_batch"; exit 0 ); }
# Hand-overs the bash loop receives, counted with builtins only (no fork).
HANDOVERS="${TMP}/handovers"
eval "_perf_real_$(declare -f status_raw_candidate_seen)"
status_raw_candidate_seen() { printf 'sap\n' >> "${HANDOVERS}"; _perf_real_status_raw_candidate_seen "$@"; }
eval "_perf_real_$(declare -f preview_decode_raw_if_requested)"
preview_decode_raw_if_requested() { printf 'preview\n' >> "${HANDOVERS}"; _perf_real_preview_decode_raw_if_requested "$@"; }
restore_state_handovers() { restore_state; : > "${HANDOVERS}"; }
listen_block() {  # what the pure LISTEN wmbusmeters prints for the known candidate
  printf 'Received telegram from: %s\n          manufacturer: (QDS) Qundis\n' "${CANDIDATE_ID}"
  printf '                  type: Water meter (0x07)\n                driver: qwaterv2\n'
}
for (( n = 1; n <= LEDGER_BATCH; n++ )); do listen_block; done > "${TMP}/listen_batch"
run_ledger_listen() { ( set +e; _listen_parse_stage < "${TMP}/listen_batch" >/dev/null 2>&1; exit 0 ); }
# shellcheck disable=SC2329  # run by measure
run_ledger_zero() {
  printf '0\n' > "${STATUS_OFFICIAL_METERS_COUNT_FILE}"
  ( set +e; _listen_parse_stage zero < "${TMP}/listen_batch" >/dev/null 2>&1; exit 0 )
  printf '1\n' > "${STATUS_OFFICIAL_METERS_COUNT_FILE}"
}
eval "_perf_real_$(declare -f emit_snippet_if_new)"
emit_snippet_if_new() { printf 'snippet\n' >> "${HANDOVERS}"; _perf_real_emit_snippet_if_new "$@"; }
eval "_perf_real_$(declare -f search_cache_candidate)"
search_cache_candidate() { printf 'search\n' >> "${HANDOVERS}"; _perf_real_search_cache_candidate "$@"; }

# The same AIR_BATCH telegrams heard by 1 and by BOARDS boards (board-major
# within a telegram, as copies arrive close together).
air_batches() {  # air_batches <boards> <dir>
  local b="$1" d="$2" n k
  mkdir -p "${d}"
  : > "${d}/rssi"; : > "${d}/rx"; : > "${d}/tracker"; : > "${d}/raw"; : > "${d}/listen"
  for (( n = 1; n <= AIR_BATCH; n++ )); do
    for (( k = 0; k < b; k++ )); do
      printf 'wmbus/board%d/rssi/%s\t-%d\n' "${k}" "${METER_ID}" $(( 50 + n % 40 )) >> "${d}/rssi"
      printf 'wmbus/board%d/rx\t{"schema":1,"boot_id":"A84F12C%d","seq":%d,"rx_task_wakeup_us":1,"meter_id":"%s","mode":"T1","frame_crc32":"7F56A83C","frame_length":123,"received_at":"2026-10-02T10:00:00.123Z"}\n' \
        "${k}" "${k}" "${n}" "${METER_ID}" >> "${d}/rx"
      printf 'wmbus/board%d/telegram\t%s\n' "${k}" "${RAW_HEX}" >> "${d}/tracker"
      printf '%s\n' "${RAW_HEX}" >> "${d}/raw"
      listen_block >> "${d}/listen"
    done
  done
}
air_batches 1 "${TMP}/air1"
air_batches "${BOARDS}" "${TMP}/air${BOARDS}"
AIR_DIR=""
air_rssi() { python3 "${BRIDGE_LEDGER}" rssi --meter-dir "${METER_DIR}" --rssi-file "${STATUS_RSSI_FILE}" < "${AIR_DIR}/rssi"; }
air_rx() {
  python3 "${BRIDGE_LEDGER}" rx \
    --reception-file "${STATUS_ESP_RX_RECEPTION_FILE}" --mode-file "${STATUS_ESP_RX_MODE_FILE}" \
    --history-file "${ESP_RF_RX_HISTORY_FILE}" --sequence-file "${STATUS_ESP_RX_SEQUENCE_FILE}" \
    --boots-file "${STATUS_ESP_RX_BOOTS_FILE}" --clock-file "${STATUS_ESP_RX_CLOCK_FILE}" < "${AIR_DIR}/rx"
}
air_tracker() {
  python3 "${BRIDGE_LEDGER}" tracker --dev-pos 1 \
    --devices-file "${STATUS_ESP_TELEGRAM_DEVICES_FILE}" --meter-device-file "${STATUS_ESP_METER_DEVICE_FILE}" \
    --reception-file "${STATUS_ESP_METER_RECEPTION_FILE}" --history-file "${ESP_RX_HISTORY_FILE}" < "${AIR_DIR}/tracker"
}
air_raw() { ( set +e; _raw_counter_stage < "${AIR_DIR}/raw"; exit 0 ); }
air_listen() { ( set +e; _listen_parse_stage < "${AIR_DIR}/listen" >/dev/null 2>&1; exit 0 ); }
run_ledger_rssi() {
  python3 "${BRIDGE_LEDGER}" rssi --meter-dir "${METER_DIR}" --rssi-file "${STATUS_RSSI_FILE}" \
    < "${TMP}/rssi_batch"
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

  measure restore_state run_ledger_rssi
  R[ledger_rssi,${m}]="${MEASURED}"
  [[ "$(awk -F '\t' -v id="${METER_ID}" '$1==id && $3 ~ /^board[0-4]$/' "${STATUS_RSSI_FILE}" | wc -l)" == "5" ]] \
    || fail "bridge_ledger.py rssi did not store one row per board (fixture broken)"

  measure restore_state run_ledger_rx
  R[ledger_rx,${m}]="${MEASURED}"
  [[ "$(wc -l < "${ESP_RF_RX_HISTORY_FILE}" | tr -d ' ')" == "${LEDGER_BATCH}" ]] \
    || fail "bridge_ledger.py rx did not book every message (fixture broken)"

  measure restore_state run_ledger_tracker
  R[ledger_tracker,${m}]="${MEASURED}"
  [[ "$(awk -F '\t' '$1 ~ /^board[0-4]$/ {n += $4} END {print n}' "${STATUS_ESP_TELEGRAM_DEVICES_FILE}")" == "${LEDGER_BATCH}" ]] \
    || fail "bridge_ledger.py tracker did not count every message (fixture broken)"

  measure restore_state run_ledger_raw
  R[ledger_raw,${m}]="${MEASURED}"
  [[ "$(cat "${STATUS_RAW_COUNT_FILE}")" == "$(( 1000 + LEDGER_BATCH ))" ]] \
    || fail "bridge_ledger.py raw did not count every telegram (fixture broken)"

  measure restore_state_handovers run_ledger_sap
  R[ledger_sap,${m}]="${MEASURED}"
  [[ "$(cat "${STATUS_RAW_COUNT_FILE}")" == "$(( 1000 + LEDGER_BATCH ))" ]] \
    || fail "bridge_ledger.py raw did not count every SAP telegram (fixture broken)"
  [[ ! -s "${HANDOVERS}" ]] \
    || fail "bridge_ledger.py raw handed $(wc -l < "${HANDOVERS}") SAP telegrams to bash; a candidate registered as it would be again needs none"
  grep -q "^${SAP_AUTO_ID}"$'\t' "${STATUS_CANDIDATE_ANALYSIS_FILE}" \
    || fail "bridge_ledger.py raw did not refresh the auto SAP candidate (fixture broken)"

  measure restore_state_handovers run_ledger_listen
  R[ledger_listen,${m}]="${MEASURED}"
  [[ ! -s "${HANDOVERS}" ]] \
    || fail "bridge_ledger.py listen handed $(wc -l < "${HANDOVERS}") blocks of a known candidate to bash"
  grep -q "^${CANDIDATE_ID}"$'\t' "${STATUS_CANDIDATE_ANALYSIS_FILE}" \
    || fail "bridge_ledger.py listen did not refresh the known candidate (fixture broken)"

  measure restore_state_handovers run_ledger_zero
  R[ledger_zero,${m}]="${MEASURED}"
  [[ ! -s "${HANDOVERS}" ]] \
    || fail "bridge_ledger.py listen --official zero handed $(wc -l < "${HANDOVERS}") blocks of a known candidate to bash"
  grep -q "^${CANDIDATE_ID}"$'\t' "${STATUS_CANDIDATE_ANALYSIS_FILE}" \
    || fail "bridge_ledger.py listen --official zero did not refresh the known candidate (fixture broken)"
done

# ── report and verdict ──────────────────────────────────────────────────────
STEPS=(meter_seen inject_rssi discovery json_total
       ledger_rssi ledger_rx ledger_tracker ledger_raw ledger_sap ledger_listen ledger_zero)
declare -A LABEL=(
  [meter_seen]="status_meter_seen"
  [inject_rssi]="inject_rssi_into_json"
  [discovery]="emit_discovery_from_json"
  [json_total]="decoded JSON path (sum)"
  [ledger_rssi]="ledger rssi, ${LEDGER_BATCH} msgs, 1 process"
  [ledger_rx]="ledger /rx, ${LEDGER_BATCH} msgs, 1 process"
  [ledger_tracker]="ledger tracker, ${LEDGER_BATCH} msgs, 1 proc"
  [ledger_raw]="ledger RAW stage, ${LEDGER_BATCH} telegrams"
  [ledger_sap]="ledger RAW stage, ${LEDGER_BATCH} known SAP"
  [ledger_listen]="ledger LISTEN, ${LEDGER_BATCH} known blocks"
  [ledger_zero]="ledger 0 meters, ${LEDGER_BATCH} known blocks"
)
declare -A BUDGET=(
  [meter_seen]="${BUDGET_METER_SEEN}"
  [inject_rssi]="${BUDGET_INJECT_RSSI}"
  [discovery]="${BUDGET_DISCOVERY}"
  [json_total]="${BUDGET_JSON_TOTAL}"
  [ledger_rssi]="${BUDGET_LEDGER_RSSI}"
  [ledger_rx]="${BUDGET_LEDGER_RX}"
  [ledger_tracker]="${BUDGET_LEDGER_TRACKER}"
  [ledger_raw]="${BUDGET_LEDGER_RAW}"
  [ledger_sap]="${BUDGET_LEDGER_SAP}"
  [ledger_listen]="${BUDGET_LEDGER_LISTEN}"
  [ledger_zero]="${BUDGET_LEDGER_ZERO}"
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

# ── boards hearing the same air ─────────────────────────────────────────────
build_fixture "${METER_COUNTS[0]}"
printf '\n%-38s%6s%6s%9s\n' "forks per batch of ${AIR_BATCH} telegrams ->" "1" "${BOARDS}" "budget"
for path in rssi rx tracker raw listen; do
  declare -A AIR=()
  for b in 1 "${BOARDS}"; do
    AIR_DIR="${TMP}/air${b}"
    measure restore_state_handovers "air_${path}"
    AIR[${b}]="${MEASURED}"
    [[ ! -s "${HANDOVERS}" ]] || fail "${path}, ${b} boards: $(wc -l < "${HANDOVERS}") messages handed to bash"
    case "${path}" in
      rssi) got="$(awk -F '\t' -v id="${METER_ID}" '$1==id && $3 ~ /^board[0-4]$/' "${STATUS_RSSI_FILE}" | wc -l)"; want="${b}" ;;
      rx) got="$(wc -l < "${ESP_RF_RX_HISTORY_FILE}")"; want=$(( AIR_BATCH * b )) ;;
      tracker) got="$(awk -F '\t' '$1 ~ /^board[0-4]$/ {n += $4} END {print n + 0}' "${STATUS_ESP_TELEGRAM_DEVICES_FILE}")"; want=$(( AIR_BATCH * b )) ;;
      raw) got="$(cat "${STATUS_RAW_COUNT_FILE}")"; want=$(( 1000 + AIR_BATCH * b )) ;;
      listen) got="$(grep -c "^${CANDIDATE_ID}"$'\t' "${STATUS_CANDIDATE_ANALYSIS_FILE}")"; want=1 ;;
    esac
    [[ "${got// /}" == "${want}" ]] || fail "${path}, ${b} boards: booked ${got} instead of ${want} (fixture broken)"
  done
  case "${path}" in
    raw) budget="${BUDGET_LEDGER_RAW}" ;;
    listen) budget="${BUDGET_LEDGER_LISTEN}" ;;
    *) budget=2 ;;
  esac
  printf '%-38s%6s%6s%9s\n' "ledger ${path}, boards" "${AIR[1]}" "${AIR[${BOARDS}]}" "${budget}"
  if (( AIR[${BOARDS}] > budget )); then
    failures+=("ledger ${path}: ${AIR[${BOARDS}]} forks for ${AIR_BATCH} telegrams from ${BOARDS} boards, budget ${budget}")
  fi
  if (( AIR[${BOARDS}] - AIR[1] > SCALE_TOLERANCE )); then
    failures+=("ledger ${path}: cost grows with boards - ${AIR[1]} forks from 1 board, ${AIR[${BOARDS}]} from ${BOARDS} for the same ${AIR_BATCH} telegrams; a message now costs a process")
  fi
done

if (( ${#failures[@]} > 0 )); then
  for f in "${failures[@]}"; do echo "FAIL: ${f}" >&2; done
  exit 1
fi
echo "OK: fork budget per telegram holds and does not grow with meters on air or with boards"
