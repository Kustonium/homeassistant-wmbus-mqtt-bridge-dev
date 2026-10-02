#!/usr/bin/env bash
# Regression test: the RAW counter (formerly status_raw_seen) booked by bridge_ledger.py.
#
# Every RAW telegram from every board passes the decode pipeline's tee into
# _raw_counter_stage. With bridge_ledger.py it writes the counter, last-seen
# time, the recent-RAW ring, the candidate manufacturer fill, the every-25th
# event, the per-minute rate and status.json, and asks the bash loop behind it
# to register Diehl/SAP candidates and start preview one-shots. This test runs
# corpora through the stage and compares with what the former bash counter
# (status_raw_seen, one call per line) wrote for them - recorded before it was
# removed, in tests/fixtures/ledger/raw/:
#   - every file the counter writes, byte for byte apart from the time;
#   - the decisions handed to bash: status_candidate_seen for SAP frames and
#     the preview one-shot reaching its slot (both stubbed to log the call, so
#     no decoder runs and the comparison does not depend on timing).
# Then python3 is killed in the middle of a stream: the stage must start it
# again and lose at most the telegram being handled.
#
# The file paths are the ones bridge.sh derives from ${BASE}.
# The clock and the ledger mode are set in subshells on purpose (SC2030/SC2031).
# shellcheck disable=SC2034,SC2153,SC2030,SC2031
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_SH="${ROOT}/rootfs/usr/bin/bridge.sh"
LIB_DIR="${ROOT}/rootfs/usr/bin/bridge-lib"
BRIDGE_LEDGER="${ROOT}/rootfs/usr/bin/bridge_ledger.py"
FIXTURES="${ROOT}/tests/fixtures"

fail() { echo "FAIL: $*" >&2; exit 1; }
for _bin in python3 jq flock awk; do
  command -v "${_bin}" >/dev/null 2>&1 || fail "missing ${_bin}"
done

TMP="$(mktemp -d)"
STAGE_PID=""
cleanup() {
  if [[ -n "${STAGE_PID}" ]]; then
    pkill -KILL -P "${STAGE_PID}" 2>/dev/null || true
    kill -KILL "${STAGE_PID}" 2>/dev/null || true
  fi
  wait 2>/dev/null || true
  rm -rf "${TMP}"
}
trap cleanup EXIT

BASE="${TMP}/data"
while IFS= read -r _assign; do
  _src="${_assign#*=\"\$\{}"
  _src="${_src%%\}*}"
  [[ -n "${!_src+x}" ]] || continue
  eval "${_assign}"
done < <(grep -E '^[A-Z_][A-Z0-9_]*="\$\{[A-Z_][A-Z0-9_]*\}[^"$`]*"$' "${BRIDGE_SH}")

for _lib in "${LIB_DIR}"/*.sh; do
  # shellcheck disable=SC1090
  source "${_lib}"
done
log() { :; }
warn() { :; }
mqtt_pub() { :; }

# What bridge.sh has set when a pipeline starts; the counter inherits these.
LOGLEVEL="normal"
RAW_TOPIC="wmbus/+/telegram"
STATE_PREFIX="wmbusmeters"
DISCOVERY_PREFIX="homeassistant"
SEARCH_MODE="false"
MQTT_HOST="core-mosquitto"
MQTT_PORT="1883"
STATUS_MQTT_CONNECTED="true"
STATUS_WMBUSMETERS_RUNNING="false"
STATUS_DECODED_COUNT=0
STATUS_DISCOVERY_PUBLISHED="false"
STATUS_DISCOVERY_PUBLISHED_AT=""
STATUS_LAST_DECODED_SEEN=""
STATUS_LAST_ERROR="pipeline exited rc=1"
STATUS_LAST_EVENT="MQTT broker ready"

# The two hand-overs to bash, logged instead of run.
DECISIONS="${TMP}/decisions"
eval "real_$(declare -f status_candidate_seen)"
# shellcheck disable=SC2329  # called by the sourced bridge-lib code
status_candidate_seen() { printf 'register\t%s\t%s\t%s\n' "$1" "$2" "$3" >> "${DECISIONS}"; }
# shellcheck disable=SC2154  # id: a local of preview_decode_raw_if_requested, the caller
_preview_acquire_slot() { printf 'preview\t%s\n' "${id}" >> "${DECISIONS}"; return 1; }

hexof() { tr -d '[:space:]' < "$1"; }
QWATER="$(hexof "${FIXTURES}/qwaterv2/52632878.hex")"
OTHER="${QWATER:0:8}44556677${QWATER:16}"          # 77665544, QDS
IZAR1="$(hexof "${FIXTURES}/izar/2156B4C2.hex")"     # SAP 0x304C
IZAR2="$(hexof "${FIXTURES}/izar/215F908A.hex")"
IZAR3="${IZAR1:0:8}33221100${IZAR1:16}"             # 00112233, SAP, driver known
IZAR4="${IZAR1:0:8}77665511${IZAR1:16}"             # 11556677, SAP, encrypted type
IZAR5="${IZAR1:0:8}88776655${IZAR1:16}"             # 55667788, SAP, empty driver field
ABCD="${QWATER:0:8}12EFCDAB${QWATER:16}"            # ABCDEF12: preview file named in lower case

seed() {
  rm -rf "${BASE}"
  mkdir -p "${BASE}" "${PREVIEW_METER_DIR}" "${BASE}/.preview_decode_last" \
    "${BASE}/.preview_decode_locks" "${BASE}/.preview_decode_slots" "${BASE}/.preview_attempts"
  local iso now n
  iso="2026-10-02T10:00:00+00:00"
  now="$(date +%s)"
  {
    printf '52632878\tqwaterv2\tWater meter (0x07)\t%s\t3\t30\t1\t2\t\n' "${iso}"
    printf '77665544\tqwaterv2\tWater meter (0x07)\t%s\t3\t30\t1\t2\tQDS\n' "${iso}"
    printf '2156B4C2\tauto\tWater meter (0x07)\t%s\t3\t30\t1\t2\n' "${iso}"
    printf '00112233\tizar\tWater meter (0x07)\t%s\t3\t30\t1\t2\t(SAP) Diehl Metering\n' "${iso}"
    printf '11556677\tauto\tWater meter (0x07) encrypted\t%s\t3\t30\t1\t2\t\n' "${iso}"
    printf '55667788\t\tWater meter (0x07)\t%s\t3\t30\t1\t2\t\n' "${iso}"
  } > "${STATUS_CANDIDATES_FILE}"
  printf 'name=preview_52632878\nid=52632878\n' > "${PREVIEW_METER_DIR}/meter-preview-52632878"
  printf 'name=preview_77665544\nid=77665544\n' > "${PREVIEW_METER_DIR}/meter-preview-77665544"
  printf 'name=preview_abcdef12\nid=abcdef12\n' > "${PREVIEW_METER_DIR}/meter-preview-abcdef12"
  printf 'name=preview_215F908A\nid=215f908a\n' > "${PREVIEW_METER_DIR}/meter-preview-215F908A"
  printf '%s\n' $(( now + 86400 )) > "${BASE}/.preview_decode_last/77665544"   # throttled
  for (( n = 0; n < 195; n++ )); do printf '%s\t4\tABCD\n' "${iso}"; done > "${STATUS_RECENT_RAW_FILE}"
  printf '%s\n' 22 > "${STATUS_RAW_COUNT_FILE}"
  printf '%s\n' "${iso}" > "${STATUS_LAST_RAW_FILE}"
  printf 'unreachable\thost:1883\n' > "${STATUS_BROKER_ERROR_FILE}"
  printf '%s\tok\told event\n' "${iso}" > "${STATUS_EVENTS_FILE}"
  printf '29000000\t5\n' > "${STATUS_RATE_HISTORY_FILE}"
  printf '%s\n' "2026-10-02T09:00:00+00:00" > "${STATUS_DISCOVERY_FLAG}"
  : > "${STATUS_SEEN_FILE}"
  : > "${DECISIONS}"
}

# Files the counter writes, and its decisions. Times become NOW: bash and
# python3 read the clock at different moments.
snapshot() {  # snapshot <dir>
  local out="$1" f
  mkdir -p "${out}"
  for f in STATUS_RAW_COUNT_FILE STATUS_LAST_RAW_FILE STATUS_RECENT_RAW_FILE STATUS_CANDIDATES_FILE \
           STATUS_EVENTS_FILE STATUS_RATE_1M_FILE STATUS_RATE_HISTORY_FILE STATUS_BROKER_ERROR_FILE \
           STATUS_JSON DECISIONS; do
    if [[ -e "${!f}" ]]; then
      sed -E -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}/ISO/g' \
             -e 's/"epoch":[0-9]+/"epoch":NOW/' "${!f}" > "${out}/${f}"
    else
      echo "<missing>" > "${out}/${f}"
    fi
  done
}

# The pipeline, and with it the counter, runs with errexit off: bridge.sh does
# `set +e` before run_once. status_raw_candidate_seen in the loop behind
# python3 relies on that (a `read` from an empty awk result returns 1 for an
# unknown SAP candidate), so the stage runs the same way here.
stage() { ( set +e; _raw_counter_stage ); }

# The run inside one minute, as the recording was, so the per-minute rate is
# comparable.
same_minute() { while (( $(date +%S | sed 's/^0//') > 45 )); do sleep 1; done; }

# ── equivalence ─────────────────────────────────────────────────────────────
CORPUS="${TMP}/corpus"
{
  printf '%s\n' "${QWATER}"    # 23: fill (QDS) Qundis; preview 52632878
  printf '%s\n' "${OTHER}"     # bare QDS code replaced; preview throttled
  printf '%s\n' "${IZAR1}"     # SAP, auto: registered; manufacturer filled
  printf '%s\n' "${IZAR2}"     # SAP, no row: registered; preview by A-field fallback
  printf '%s\n' "${IZAR3}"     # SAP, driver izar: not registered
  printf '%s\n' "${IZAR4}"     # SAP, encrypted: not registered
  printf '%s\n' "${IZAR5}"     # SAP, empty driver: read shifts the type into it
  printf '%s\n' "${ABCD}"      # preview file in lower case: no decode
  printf ' %s \n' "${QWATER,,}"  # spaces, lower case: not a ring entry, still counted
  printf '\n'
  printf 'ZZZZ\n'
  printf '%s\n' "${QWATER:0:40}"
  for _ in 1 2 3 4 5 6 7 8; do printf '%s\n' "${OTHER}"; done   # crosses the 25th telegram
  printf '%s\n' "${QWATER}"
} > "${CORPUS}"

GOLDEN="${ROOT}/tests/fixtures/ledger/raw"
same_minute
seed
# python3 hands work to the bash loop asynchronously; the slow feed keeps
# each hand-over finished before the next telegram, as on a real site.
while IFS= read -r line; do printf '%s\n' "${line}"; sleep 0.05; done < "${CORPUS}" | stage
snapshot "${TMP}/py"

for f in "${GOLDEN}/equivalence"/*; do
  name="$(basename "${f}")"
  if ! diff -u "${f}" "${TMP}/py/${name}" > "${TMP}/diff"; then
    cat "${TMP}/diff" >&2
    fail "${name} differs from what status_raw_seen wrote (tests/fixtures/ledger/raw/equivalence)"
  fi
done
grep -q $'^register\t2156B4C2' "${TMP}/py/DECISIONS" || fail "no SAP registration was handed over - the corpus tests nothing"
grep -q $'^preview\t52632878' "${TMP}/py/DECISIONS" || fail "no preview was handed over - the corpus tests nothing"
expected=$(( 22 + $(wc -l < "${CORPUS}") ))
[[ "$(cat "${STATUS_RAW_COUNT_FILE}")" == "${expected}" ]] || fail "counter did not reach ${expected}"

# ── Diehl/SAP candidate already registered as auto ──────────────────────────
# Real IZAR frames carry device type 01, so bash registers them as driver auto
# with the device-type label on every telegram. When the row already holds
# exactly that and the preview config would stay as it is, bridge_ledger.py
# writes the reception refresh itself (seen row with its 2 s threshold, stats,
# candidate row, RAW analysis) and nothing reaches bash. status_candidate_seen
# is the real one here, so every file must be identical to what the bash
# counter wrote (tests/fixtures/ledger/raw/sap.dump).
# The clock is fixed per batch (date in bash, time.time in python3): the 2 s
# threshold and the stats depend on it.
mkdir -p "${TMP}/clock"
printf '%s\n' 'import os, time' \
  'if os.environ.get("LEDGER_TEST_EPOCH"): time.time = lambda: float(os.environ["LEDGER_TEST_EPOCH"])' \
  > "${TMP}/clock/sitecustomize.py"
# shellcheck disable=SC2329  # called by the sourced bridge-lib code
date() {
  case "$*" in
    +%s) echo "${LEDGER_TEST_EPOCH}" ;;
    -Iseconds) command date -u -d "@${LEDGER_TEST_EPOCH}" '+%Y-%m-%dT%H:%M:%S+00:00' ;;
    *) command date "$@" ;;
  esac
}
# shellcheck disable=SC2329  # called by the sourced bridge-lib code
status_candidate_seen() {
  printf 'register\t%s\t%s\t%s\n' "$1" "$2" "$3" >> "${DECISIONS}"
  real_status_candidate_seen "$@"
}
T0=1790935200
SAP_A="${IZAR1}"                          # 2156B4C2: auto row, preview config
SAP_B="${IZAR2}"                          # 215F908A: 8-field row, manufacturer filled first
SAP_C="${IZAR1:0:8}33221100${IZAR1:16}"   # 00112233: official meter, no preview config
SAP_D="${IZAR1:0:8}77665511${IZAR1:16}"   # 11556677: its type changes - bash registers it
seed_sap() {
  rm -rf "${BASE}"
  mkdir -p "${BASE}" "${PREVIEW_METER_DIR}" "${METER_DIR}" "${BASE}/.preview_decode_last" \
    "${BASE}/.preview_decode_locks" "${BASE}/.preview_decode_slots" "${BASE}/.preview_attempts"
  local t="Unknown meter type (0x01)" id
  {
    printf '2156B4C2\tauto\t%s\tOLD\t3\t30\t1\t2\t(SAP) Diehl Metering\n' "${t}"
    printf '77665544\tqwaterv2\tWater meter (0x07)\tOLD\t3\t30\t1\t2\tQDS\n'
    printf '215F908A\tauto\t%s\tOLD\t3\t30\t1\t2\n' "${t}"
    printf '00112233\tauto\t%s\tOLD\t3\t30\t1\t2\t\n' "${t}"
    printf '11556677\tauto\tWater meter (0x07)\tOLD\t3\t30\t1\t2\t\n'
  } > "${STATUS_CANDIDATES_FILE}"
  for id in 2156B4C2 215F908A; do
    printf 'name=preview_%s\nid=%s\n' "${id}" "${id,,}" > "${PREVIEW_METER_DIR}/meter-preview-${id}"
  done
  printf 'name=official\nid=00112233\ndriver=izar\n' > "${METER_DIR}/meter-official"
  for id in 2156B4C2 215F908A 11556677; do
    printf '%s\n' $(( T0 + 86400 )) > "${BASE}/.preview_decode_last/${id}"   # no one-shot here
  done
  for id in 2156B4C2 215F908A 00112233 11556677; do
    printf '%s\tcandidate\t%s\n%s\tmeter\t%s\n' "${id}" $(( T0 - 4000 )) "${id}" $(( T0 - 700 ))
  done > "${STATUS_SEEN_FILE}"
  # The decoding pipeline's row for the same transmission: one reception in the stats.
  printf '2156B4C2\tmeter\t%s\n' $(( T0 - 1 )) >> "${STATUS_SEEN_FILE}"
  printf '2156B4C2\tOLD\t4\tabcd\n' > "${STATUS_CANDIDATE_RAW_FILE}"
  printf '2156B4C2\tunknown\told\t\t\t4\tOLD\n' > "${STATUS_CANDIDATE_ANALYSIS_FILE}"
  printf '%s\n' 22 > "${STATUS_RAW_COUNT_FILE}"
  : > "${DECISIONS}"
}
# Everything under ${BASE} but the lock files (python3 also locks the seen file).
dump() {
  ( cd "${BASE}" && find . -type f ! -name '*.lock' | LC_ALL=C sort \
      | while IFS= read -r f; do printf '== %s\n' "${f}"; cat "${f}"; done ) > "$1"
}
# One batch per clock value. A batch's only hand-over is its last frame, and
# the stage returns when the bash loop has finished it, so the python3 run is
# as deterministic as the bash one.
sap_batches() {  # sap_batches
  local e frames
  for e in "0 A B C A" "1 A B" "2 B" "5 A C D"; do
    frames=()
    for f in ${e#* }; do v="SAP_${f}"; frames+=("${!v}"); done
    printf '%s\n' "${frames[@]}" | (
      export LEDGER_TEST_EPOCH=$(( T0 + ${e%% *} )) PYTHONPATH="${TMP}/clock"
      # The loop's status is that of the last request it ran; status_candidate_seen
      # ends on `[[ false == true ]] && ...`. Nothing in the pipeline reads it.
      stage || true )
  done
}
seed_sap
sap_batches
dump "${TMP}/sap_py"
diff -u "${GOLDEN}/sap.dump" "${TMP}/sap_py" >&2 \
  || fail "SAP auto refresh: files differ from what status_raw_seen wrote (tests/fixtures/ledger/raw/sap.dump)"
# The bash counter registered the corpus 10 times; only the type change may
# still reach bash.
[[ "$(cat "${DECISIONS}")" == $'register\t11556677\tauto\tUnknown meter type (0x01)' ]] \
  || { cat "${DECISIONS}" >&2; fail "SAP auto refresh: only the type change of 11556677 may reach bash"; }
[[ "$(grep -c $'^215F908A\tcandidate\t' "${STATUS_SEEN_FILE}")" == 3 ]] \
  || fail "SAP auto refresh: 215F908A at +0, +1 and +2 s must be booked at +0 and +2 s only"
status_candidate_seen() { printf 'register\t%s\t%s\t%s\n' "$1" "$2" "$3" >> "${DECISIONS}"; }

# ── preview one-shot interval by state ──────────────────────────────────────
# A candidate whose preview shows a value (decoded_value) is decoded again at
# most every PREVIEW_DECODED_MIN_INTERVAL_SECONDS (300 s); pending and
# no_decode_result keep the 20 s throttle. The last one-shot of every candidate
# ran at T0; the one-shot itself is the logging stub, so it does not move that.
PV_D="${QWATER:0:8}11111111${QWATER:16}"   # 11111111: decoded_value
PV_P="${QWATER:0:8}22222222${QWATER:16}"   # 22222222: pending
PV_N="${QWATER:0:8}33333333${QWATER:16}"   # 33333333: no_decode_result
seed_preview() {
  rm -rf "${BASE}"
  mkdir -p "${BASE}" "${PREVIEW_METER_DIR}" "${METER_DIR}" "${BASE}/.preview_decode_last" \
    "${BASE}/.preview_decode_locks" "${BASE}/.preview_decode_slots" "${BASE}/.preview_attempts"
  local id state
  for id in 11111111 22222222 33333333; do
    printf 'name=preview_%s\nid=%s\ndriver=qwaterv2\n' "${id}" "${id}" > "${PREVIEW_METER_DIR}/meter-preview-${id}"
    printf '%s\n' "${T0}" > "${BASE}/.preview_decode_last/${id}"
  done
  for state in "11111111 decoded_value" "22222222 pending" "33333333 no_decode_result"; do
    printf '%s\t%s\t2026-10-02T10:00:00+00:00\t\n' "${state%% *}" "${state#* }"
  done > "${STATUS_CANDIDATE_PREVIEW_STATE_FILE}"
  : > "${STATUS_CANDIDATES_FILE}"
  printf '%s\n' 22 > "${STATUS_RAW_COUNT_FILE}"
  : > "${DECISIONS}"
}
# Hand-overs of the python3 run: within 300 s a decoded_value candidate must
# not even be asked of bash (each request costs a bash call).
eval "real_$(declare -f preview_decode_raw_if_requested)"
# shellcheck disable=SC2329  # called by the stage
preview_decode_raw_if_requested() { [[ -n "${2:-}" ]] && printf '%s\n' "$2" >> "${TMP}/preview_requests"; real_preview_decode_raw_if_requested "$@"; }
preview_at() {  # preview_at <seconds after T0> <frame>...
  local offset="$1"
  shift
  printf '%s\n' "$@" | (
    export LEDGER_TEST_EPOCH=$(( T0 + offset )) PYTHONPATH="${TMP}/clock"
    stage || true )
}
seed_preview
: > "${TMP}/preview_requests"
for offset in 21 150 299; do preview_at "${offset}" "${PV_D}"; done
[[ ! -s "${DECISIONS}" ]] \
  || { cat "${DECISIONS}" >&2; fail "decoded_value decoded again within 300 s"; }
[[ ! -s "${TMP}/preview_requests" ]] || fail "decoded_value handed to bash within 300 s"
preview_at 300 "${PV_D}"
[[ "$(cat "${DECISIONS}")" == $'preview\t11111111' ]] \
  || { cat "${DECISIONS}" >&2; fail "decoded_value not decoded again after 300 s"; }
: > "${DECISIONS}"
preview_at 10 "${PV_P}" "${PV_N}"
[[ ! -s "${DECISIONS}" ]] \
  || { cat "${DECISIONS}" >&2; fail "pending/no_decode_result decoded within the 20 s throttle"; }
preview_at 21 "${PV_P}" "${PV_N}"
[[ "$(cat "${DECISIONS}")" == $'preview\t22222222\npreview\t33333333' ]] \
  || { cat "${DECISIONS}" >&2; fail "pending/no_decode_result not decoded after 20 s"; }
# bash repeats the rule when it is asked directly (ensure_candidate_autodecode
# calls it, and it guards every request it gets).
seed_preview
for offset in 21 299; do
  ( LEDGER_TEST_EPOCH=$(( T0 + offset )); real_preview_decode_raw_if_requested "${PV_D}" 11111111 ) || true
done
[[ ! -s "${DECISIONS}" ]] \
  || { cat "${DECISIONS}" >&2; fail "bash: decoded_value decoded again within 300 s"; }
( LEDGER_TEST_EPOCH=$(( T0 + 300 )); real_preview_decode_raw_if_requested "${PV_D}" 11111111 ) || true
( LEDGER_TEST_EPOCH=$(( T0 + 21 )); real_preview_decode_raw_if_requested "${PV_P}" 22222222 ) || true
[[ "$(cat "${DECISIONS}")" == $'preview\t11111111\npreview\t22222222' ]] \
  || { cat "${DECISIONS}" >&2; fail "bash: the 300 s / 20 s rule does not hold"; }
unset -f date

# ── restart after python3 dies ──────────────────────────────────────────────
seed
MESSAGES=40
FEED="${TMP}/feed"
mkfifo "${FEED}"
( trap '' PIPE; stage < "${FEED}" ) 2>"${TMP}/stage.err" &
STAGE_PID=$!
exec {feed_fd}>"${FEED}"
for (( i = 1; i <= MESSAGES; i++ )); do
  printf '%s\n' "${OTHER}" >&"${feed_fd}"
  sleep 0.05
  if (( i == 15 )); then
    pkill -KILL -f "${BRIDGE_LEDGER} raw --raw-count-file=${STATUS_RAW_COUNT_FILE}" \
      || fail "restart: no bridge_ledger.py raw process to kill"
    sleep 1.2   # the stage waits 1 s before starting python3 again
  fi
done
exec {feed_fd}>&-
wait "${STAGE_PID}" || true
STAGE_PID=""
final=$(( $(cat "${STATUS_RAW_COUNT_FILE}") - 22 ))
(( final >= MESSAGES - 1 )) \
  || { cat "${TMP}/stage.err" >&2; fail "restart: ${final} of ${MESSAGES} telegrams counted; more than the one in flight was lost"; }
jq -e ".pipeline.raw_count == $(( 22 + final ))" "${STATUS_JSON}" >/dev/null \
  || fail "restart: status.json does not show the final count"

echo "PASS: RAW counter via bridge_ledger.py matches the recorded bash output and survives python3 dying (${final}/${MESSAGES} counted)"
