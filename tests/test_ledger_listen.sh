#!/usr/bin/env bash
# Regression test: the parser of the pure LISTEN instance in bridge_ledger.py.
#
# Every telegram heard by the parallel LISTEN wmbusmeters becomes a text block
# ("Received telegram from:", type:, driver:, manufacturer:) that the former
# bash parser (parse_listen_candidates) booked with ~60 processes per block.
# With bridge_ledger.py the block of a candidate that is already registered
# with the same driver and type, already announced and whose preview config
# would stay as it is, is booked in python3 (candidate_seen_refresh, shared
# with the RAW stage); new and changed candidates, SEARCH and decoded JSON go
# to the bash loop behind it. This test feeds recorded `wmbusmeters --listen`
# output (tests/fixtures/listen) through _listen_parse_stage and checks:
#   - every file under the data directory and the log lines are what the bash
#     parser wrote for the same batches - recorded before it was removed, in
#     tests/fixtures/ledger/listen/ - with the clock fixed per batch (date in
#     bash, time.time in python3);
#   - once every candidate is known, nothing reaches bash;
#   - python3 killed between two blocks is started again and loses at most the
#     block it held;
#   - the preview states: pending -> one-shot -> decoded_value (needs
#     wmbusmeters, i.e. the add-on image), and pending for >300 s ->
#     no_decode_result, and LISTEN blocks booked by python3 afterwards leave
#     either state alone.
#
# The file paths are the ones bridge.sh derives from ${BASE}. The clock is set
# in subshells on purpose (SC2030/SC2031).
# shellcheck disable=SC2034,SC2153,SC2030,SC2031
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_SH="${ROOT}/rootfs/usr/bin/bridge.sh"
LIB_DIR="${ROOT}/rootfs/usr/bin/bridge-lib"
BRIDGE_LEDGER="${ROOT}/rootfs/usr/bin/bridge_ledger.py"
LISTEN_OUT="${ROOT}/tests/fixtures/listen/wmbusmeters-listen.txt"
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
# The status files are defined from ${RUNTIME} (the RAM directory in the
# add-on); without a tmpfs it is ${BASE}, as here.
RUNTIME="${BASE}"
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
mqtt_pub() { :; }

# What bridge.sh has set when the LISTEN instance starts.
LOGLEVEL="debug"
SEARCH_MODE="false"
SEARCH_EXPECTED_VALUE_M3="0"
OFFICIAL_METERS_COUNT=1

# Fixed clock: date in bash, time.time in python3 (sitecustomize).
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
# The preview one-shot is logged instead of run in the equivalence part.
eval "real_$(declare -f _preview_acquire_slot)"
# shellcheck disable=SC2329,SC2154  # called by the sourced bridge-lib code; id: its caller's local
_preview_acquire_slot() { printf '%s\n' "${id}" >> "${TMP}/oneshots"; return 1; }
# Hand-overs reaching bash.
# shellcheck disable=SC2329  # called by _listen_parse_stage
eval "real_$(declare -f emit_snippet_if_new)"
emit_snippet_if_new() { printf 'snippet %s %s\n' "$1" "$2" >> "${TMP}/handovers"; real_emit_snippet_if_new "$@"; }
eval "real_$(declare -f _process_listen_json_line)"
_process_listen_json_line() { printf 'json\n' >> "${TMP}/handovers"; real__process_listen_json_line "$@"; }

T0=1790935200
OFFICIAL_ID="03264950"   # hydrodigit in the recording: a configured meter
seed() {
  rm -rf "${BASE}"
  mkdir -p "${BASE}" "${PREVIEW_METER_DIR}" "${METER_DIR}" "${BASE}/.preview_decode_last" \
    "${BASE}/.preview_decode_locks" "${BASE}/.preview_decode_slots" "${BASE}/.preview_attempts"
  printf 'name=water\nid=%s\ndriver=hydrodigit\n' "${OFFICIAL_ID,,}" > "${METER_DIR}/meter-0001"
  printf '1\n' > "${STATUS_OFFICIAL_METERS_COUNT_FILE}"
  # One candidate the RAW path registered earlier, manufacturer as a bare code.
  printf '52632878\tauto\tWater meter (0x07)\tOLD\t3\t30\t1\t2\tQDS\n' > "${STATUS_CANDIDATES_FILE}"
  : > "${STATUS_SEEN_FILE}"
  : > "${SNIPPET_STATE}"
  # The ring holds the RAW frames, so the analysis finds them.
  local f
  for f in "${FIXTURES}"/*/*.hex; do
    printf '2026-10-02T09:59:00+00:00\t%s\t%s\n' "$(tr -d '[:space:]' < "${f}" | wc -c)" "$(tr -d '[:space:]' < "${f}")"
  done > "${STATUS_RECENT_RAW_FILE}"
  : > "${TMP}/oneshots"
  : > "${TMP}/handovers"
}
dump() {
  ( cd "${BASE}" && find . -type f ! -name '*.lock' | LC_ALL=C sort \
      | while IFS= read -r f; do printf '== %s\n' "${f}"; cat "${f}"; done ) > "$1"
  printf '== oneshots\n' >> "$1"
  cat "${TMP}/oneshots" >> "$1"
}
# A batch at a fixed clock. The stage returns when the bash loop has done
# every hand-over; a batch hands over only at its end (or only), so the run is
# deterministic.
batch() {  # batch <offset> <file>
  ( export LEDGER_TEST_EPOCH=$(( T0 + $1 )) PYTHONPATH="${TMP}/clock"
    set +e
    _listen_parse_stage < "$2" ) >> "${TMP}/log" 2>&1 || true
}

block_of() {  # the block of one meter id in a recording
  awk -v id="$1" '/^Received telegram from:/ { on = (tolower($4) == tolower(id)) } on' "${2:-${LISTEN_OUT}}"
}
# The recording plus a block without a type: line (the parser books "listen").
CORPUS="${TMP}/corpus.txt"
{ cat "${LISTEN_OUT}"; printf 'Received telegram from: 44556677\n                driver: qwaterv2\n'; } > "${CORPUS}"
# The last batch: known blocks, then what still goes to bash (moved to the
# end): a known candidate whose preview config is gone, one never announced,
# a type change, a driver change and a decoded JSON line.
CHANGED="${TMP}/changed.txt"
{
  awk '/^Received telegram from:/ { on = ($4 !~ /^(67433753|53119425|32131245)$/) } on' "${CORPUS}"
  block_of 67433753
  block_of 53119425
  block_of 32131245 | sed 's/(0x80)/(0x08)/'
  printf 'Received telegram from: 21031894\n          manufacturer: (MAD) Maddalena, Italy (0x3424)\n'
  printf '                  type: Cold water meter (0x16)\n                driver: evo868v2\n'
  jq -c '. + {timestamp: "2026-10-02T10:00:00Z"}' "${FIXTURES}/qwaterv2/52632878.golden.json"
} > "${CHANGED}"

run_all() {
  : > "${TMP}/log"
  seed
  batch 0 "${CORPUS}"
  cp "${TMP}/handovers" "${TMP}/handovers.new"
  : > "${TMP}/handovers"
  batch 1 "${CORPUS}"
  printf '0\n' > "${STATUS_OFFICIAL_METERS_COUNT_FILE}"   # no official meters: nothing booked
  batch 3 "${CORPUS}"
  printf '1\n' > "${STATUS_OFFICIAL_METERS_COUNT_FILE}"
  batch 5 "${CORPUS}"
  cp "${TMP}/handovers" "${TMP}/handovers.known"
  : > "${TMP}/handovers"
  # A full manufacturer text the block replaces; an id missing from seen_ids.
  sed -i -E $'s/^(67250945\t.*\t)[^\t]*$/\\1(LSE) Landis old name/' "${STATUS_CANDIDATES_FILE}"
  sed -i '/^53119425$/d' "${SNIPPET_STATE}"
  rm -f "${PREVIEW_METER_DIR}/meter-preview-67433753"
  batch 9 "${CHANGED}"
  cp "${TMP}/handovers" "${TMP}/handovers.changed"
  dump "${TMP}/dump"
}

# ── equivalence ─────────────────────────────────────────────────────────────
GOLDEN="${ROOT}/tests/fixtures/ledger/listen"
run_all
diff -u "${GOLDEN}/files.dump" "${TMP}/dump" >&2 \
  || fail "files differ from what parse_listen_candidates wrote (tests/fixtures/ledger/listen/files.dump)"
diff -u "${GOLDEN}/log.sorted" <(LC_ALL=C sort "${TMP}/log" | sed "s#${TMP}#TMP#g") >&2 \
  || fail "log lines differ from what parse_listen_candidates logged (tests/fixtures/ledger/listen/log.sorted)"
[[ "$(wc -l < "${TMP}/handovers.new")" -ge 12 ]] \
  || fail "the recording registered only $(wc -l < "${TMP}/handovers.new") candidates - it tests nothing"
[[ ! -s "${TMP}/handovers.known" ]] \
  || { cat "${TMP}/handovers.known" >&2; fail "known candidates were handed to bash"; }
[[ "$(cat "${TMP}/handovers.changed")" == $'snippet 67433753 qheatv2\nsnippet 53119425 kamwater\nsnippet 32131245 fhkvdataiii\njson\nsnippet 21031894 evo868v2' ]] \
  || { cat "${TMP}/handovers.changed" >&2; fail "only the preview change, the unannounced candidate, the type and driver changes and the JSON line may reach bash"; }
grep -q $'^67250945\t.*\t(LSE) Landis Staefa electronic (0xb265)$' "${STATUS_CANDIDATES_FILE}" \
  || fail "the block's manufacturer did not replace the stored text"
grep -q $'^44556677\tqwaterv2\tlisten\t' "${STATUS_CANDIDATES_FILE}" \
  || fail "a block without type: was not booked as \"listen\""
grep -q $'^52632878\t.*\t(QDS) Qundis, Germany (0x4493)$' "${STATUS_CANDIDATES_FILE}" \
  || fail "the manufacturer text did not replace the bare code"
[[ "$(grep -c $'^24271170\tcandidate\t' "${STATUS_SEEN_FILE}")" == 3 ]] \
  || fail "receptions at +0, +1, +5, +9 s must be booked at +0, +5 and +9 s"

# ── restart after python3 dies ──────────────────────────────────────────────
seed
MESSAGES=40
FEED="${TMP}/feed"
mkfifo "${FEED}"
( trap '' PIPE; export LEDGER_TEST_EPOCH="${T0}" PYTHONPATH="${TMP}/clock"; set +e
  _listen_parse_stage < "${FEED}" ) >/dev/null 2>"${TMP}/stage.err" &
STAGE_PID=$!
exec {feed_fd}>"${FEED}"
for (( i = 1; i <= MESSAGES; i++ )); do
  printf 'Received telegram from: %08d\n          manufacturer: (QDS) Qundis\n' "$(( 70000000 + i ))" >&"${feed_fd}"
  printf '                  type: Water meter (0x07)\n                driver: qwaterv2\n' >&"${feed_fd}"
  sleep 0.1
  if (( i == 15 )); then
    pkill -KILL -f "${BRIDGE_LEDGER} listen --candidates-file=${STATUS_CANDIDATES_FILE}" \
      || fail "restart: no bridge_ledger.py listen process to kill"
    sleep 1.2   # the stage waits 1 s before starting python3 again
  fi
done
exec {feed_fd}>&-
wait "${STAGE_PID}" || true
STAGE_PID=""
booked="$(wc -l < "${SNIPPET_STATE}")"
(( booked >= MESSAGES - 1 )) \
  || { cat "${TMP}/stage.err" >&2; fail "restart: ${booked} of ${MESSAGES} blocks booked; more than the one held was lost"; }

# ── preview states ──────────────────────────────────────────────────────────
state_of() { awk -F '\t' -v id="$1" '$1 == id { s = $2 } END { print s }' "${STATUS_CANDIDATE_PREVIEW_STATE_FILE}" 2>/dev/null; }
# pending for more than PREVIEW_PENDING_TIMEOUT_SECONDS -> no_decode_result,
# and the blocks python3 books afterwards leave the state alone.
seed
block_of 21031894 > "${TMP}/evo.txt"
batch 0 "${TMP}/evo.txt"
[[ "$(state_of 21031894)" == "pending" ]] || fail "a new candidate's preview is not pending"
sed -i -E $'s/^(21031894\tpending\t)[^\t]*/\\12020-01-01T00:00:00+00:00/' "${STATUS_CANDIDATE_PREVIEW_STATE_FILE}"
( unset -f date; expire_stale_pending_previews ) >/dev/null
[[ "$(state_of 21031894)" == "no_decode_result" ]] || fail "pending >300 s did not become no_decode_result"
: > "${TMP}/handovers"
batch 30 "${TMP}/evo.txt"
batch 60 "${TMP}/evo.txt"
[[ "$(state_of 21031894)" == "no_decode_result" ]] || fail "a LISTEN block reset no_decode_result"
[[ ! -s "${TMP}/handovers" ]] || fail "the known candidate was handed to bash"

# pending -> one-shot -> decoded_value, with the real decoder.
if [[ -x /usr/bin/wmbusmeters ]]; then
  _preview_acquire_slot() { real__preview_acquire_slot "$@"; }
  seed
  block_of 52632878 > "${TMP}/qw.txt"
  ( unset -f date; LEDGER_TEST_EPOCH="$(command date +%s)"
    export LEDGER_TEST_EPOCH PYTHONPATH="${TMP}/clock"
    set +e; _listen_parse_stage < "${TMP}/qw.txt" ) >/dev/null 2>&1 || true
  for (( n = 0; n < 100; n++ )); do
    [[ "$(state_of 52632878)" == "decoded_value" ]] && break
    sleep 0.2
  done
  [[ "$(state_of 52632878)" == "decoded_value" ]] \
    || fail "pending -> one-shot did not reach decoded_value (state: $(state_of 52632878))"
  : > "${TMP}/handovers"
  for e in 30 60; do
    ( unset -f date; export LEDGER_TEST_EPOCH="$(( $(command date +%s) + e ))" PYTHONPATH="${TMP}/clock"
      set +e; _listen_parse_stage < "${TMP}/qw.txt" ) >/dev/null 2>&1 || true
  done
  [[ "$(state_of 52632878)" == "decoded_value" ]] || fail "a LISTEN block reset decoded_value"
  oneshot="tested"
else
  oneshot="SKIPPED (no wmbusmeters; runs in the add-on image)"
fi

echo "PASS: LISTEN parser via bridge_ledger.py matches the recorded bash output, survives python3 dying (${booked}/${MESSAGES} booked); pending>300s -> no_decode_result kept; one-shot -> decoded_value ${oneshot}"
