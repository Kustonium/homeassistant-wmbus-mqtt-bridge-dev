#!/usr/bin/env bash
# Equivalence test: the listen output of the main DECODE instance while no
# meter is configured (the zero-meter mode every new installation starts in).
#
# wmbusmeters runs with no meter then and prints a "Received telegram from:"
# block per telegram, like the parallel LISTEN instance. Those blocks used to
# be parsed inline in run_once (bridge.sh) and every one booked through
# emit_snippet_if_new in bash. What that parser wrote for the recorded
# `wmbusmeters --listen` output (tests/fixtures/listen) is kept in
# tests/fixtures/ledger/zero/; the test feeds the same batches to the parser
# and compares every file, the sorted log lines and the hand-overs.
#
# ZERO_RECORD=<bridge.sh> records the golden files with the inline parser of
# that bridge.sh instead (as it was before the move).
#
# The globals below are read by the sourced bridge-lib code, which the linter
# cannot follow (SC2034); each batch sets its clock in its own subshell
# (SC2030/SC2031).
# shellcheck disable=SC2034,SC2030,SC2031
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_SH="${ROOT}/rootfs/usr/bin/bridge.sh"
LIB_DIR="${ROOT}/rootfs/usr/bin/bridge-lib"
BRIDGE_LEDGER="${ROOT}/rootfs/usr/bin/bridge_ledger.py"
LISTEN_OUT="${ROOT}/tests/fixtures/listen/wmbusmeters-listen.txt"
FIXTURES="${ROOT}/tests/fixtures"
GOLDEN="${ROOT}/tests/fixtures/ledger/zero"

fail() { echo "FAIL: $*" >&2; exit 1; }
for _bin in python3 jq flock awk; do
  command -v "${_bin}" >/dev/null 2>&1 || fail "missing ${_bin}"
done

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

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

# What bridge.sh has set when the DECODE pipeline starts with no meter.
LOGLEVEL="debug"
SEARCH_MODE="false"
SEARCH_EXPECTED_VALUE_M3="0"
SEARCH_USING_TEMP_METERS="false"
OFFICIAL_METERS_COUNT=0

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
# The preview one-shot is logged instead of run.
# shellcheck disable=SC2329,SC2154  # called by the sourced bridge-lib code; id: its caller's local
_preview_acquire_slot() { printf '%s\n' "${id}" >> "${TMP}/oneshots"; return 1; }
eval "real_$(declare -f emit_snippet_if_new)"
emit_snippet_if_new() { printf 'snippet %s %s\n' "$1" "$2" >> "${TMP}/handovers"; real_emit_snippet_if_new "$@"; }

if [[ -n "${ZERO_RECORD:-}" ]]; then
  # The inline parser of run_once, taken from that bridge.sh as it is.
  _block="$(awk '/if \[\[ "\$\(official_meters_count_current\)" -eq 0 && "\$\{SEARCH_USING_TEMP_METERS\}" != "true" \]\]; then/ { on = 1 }
                 on { print } on && /^        fi$/ { exit }' "${ZERO_RECORD}")"
  [[ -n "${_block}" ]] || fail "no inline parser in ${ZERO_RECORD}"
  eval "zero_parse() { local line last_id='' last_type='' last_driver='' last_manufacturer=''
    while IFS= read -r line; do
${_block}
    done; }"
else
  zero_parse() { _listen_parse_stage zero; }
fi

T0=1790935200
seed() {
  rm -rf "${BASE}"
  mkdir -p "${BASE}" "${PREVIEW_METER_DIR}" "${METER_DIR}" "${BASE}/.preview_decode_last" \
    "${BASE}/.preview_decode_locks" "${BASE}/.preview_decode_slots" "${BASE}/.preview_attempts"
  printf '0\n' > "${STATUS_OFFICIAL_METERS_COUNT_FILE}"
  # One candidate the RAW path registered earlier, manufacturer as a bare code.
  printf '52632878\tauto\tWater meter (0x07)\tOLD\t3\t30\t1\t2\tQDS\n' > "${STATUS_CANDIDATES_FILE}"
  : > "${STATUS_SEEN_FILE}"
  : > "${SNIPPET_STATE}"
  local f
  for f in "${FIXTURES}"/*/*.hex; do
    printf '2026-10-02T09:59:00+00:00\t%s\t%s\n' "$(tr -d '[:space:]' < "${f}" | wc -c)" "$(tr -d '[:space:]' < "${f}")"
  done > "${STATUS_RECENT_RAW_FILE}"
  : > "${TMP}/oneshots"
  : > "${TMP}/handovers"
}
dump() {
  # status.json is left out: the main loop rewrote it per block from its own
  # counters; the stage, like the LISTEN one, does not (bridge_ledger.py raw
  # keeps it current per telegram).
  ( cd "${BASE}" && find . -type f ! -name '*.lock' ! -name status.json | LC_ALL=C sort \
      | while IFS= read -r f; do printf '== %s\n' "${f}"; cat "${f}"; done ) > "$1"
  printf '== oneshots\n' >> "$1"
  cat "${TMP}/oneshots" >> "$1"
}
# The preview one-shot runs in python3 now (PreviewDecoder, compared with
# preview_decode_raw_if_requested in tests/test_preview_oneshot.py); the
# recorded one-shots are bash's, so it is handed over here as it used to be.
batch() {  # batch <offset> <file>
  ( export LEDGER_TEST_EPOCH=$(( T0 + $1 )) PYTHONPATH="${TMP}/clock"
    set +eu
    LEDGER_PREVIEW_IN_PYTHON=false zero_parse < "$2" ) >> "${TMP}/log" 2>&1 || true
}
block_of() {
  awk -v id="$1" '/^Received telegram from:/ { on = (tolower($4) == tolower(id)) } on' "${LISTEN_OUT}"
}
CORPUS="${TMP}/corpus.txt"
{ cat "${LISTEN_OUT}"; printf 'Received telegram from: 44556677\n                driver: qwaterv2\n'; } > "${CORPUS}"
CHANGED="${TMP}/changed.txt"
{
  awk '/^Received telegram from:/ { on = ($4 !~ /^(67433753|53119425|32131245)$/) } on' "${CORPUS}"
  block_of 67433753
  block_of 53119425
  block_of 32131245 | sed 's/(0x80)/(0x08)/'
  printf 'Received telegram from: 21031894\n          manufacturer: (MAD) Maddalena, Italy (0x3424)\n'
  printf '                  type: Cold water meter (0x16)\n                driver: evo868v2\n'
} > "${CHANGED}"

run_all() {
  : > "${TMP}/log"
  seed
  batch 0 "${CORPUS}"
  cp "${TMP}/handovers" "${TMP}/handovers.new"; : > "${TMP}/handovers"
  cp "${SNIPPET_STATE}" "${TMP}/announced.new"
  batch 1 "${CORPUS}"
  batch 5 "${CORPUS}"
  cp "${TMP}/handovers" "${TMP}/handovers.known"; : > "${TMP}/handovers"
  sed -i -E $'s/^(67250945\t.*\t)[^\t]*$/\\1(LSE) Landis old name/' "${STATUS_CANDIDATES_FILE}"
  sed -i '/^53119425$/d' "${SNIPPET_STATE}"
  rm -f "${PREVIEW_METER_DIR}/meter-preview-67433753"
  batch 9 "${CHANGED}"
  cp "${TMP}/handovers" "${TMP}/handovers.changed"
  dump "${TMP}/dump"
  LC_ALL=C sort "${TMP}/log" | sed "s#${TMP}#TMP#g" > "${TMP}/log.sorted"
}

run_all
if [[ -n "${ZERO_RECORD:-}" ]]; then
  mkdir -p "${GOLDEN}"
  cp "${TMP}/dump" "${GOLDEN}/files.dump"
  cp "${TMP}/log.sorted" "${GOLDEN}/log.sorted"
  for f in new known changed; do cp "${TMP}/handovers.${f}" "${GOLDEN}/handovers.${f}"; done
  echo "RECORDED: ${GOLDEN}"
  exit 0
fi

# ── equivalence ─────────────────────────────────────────────────────────────
diff -u "${GOLDEN}/files.dump" "${TMP}/dump" >&2 \
  || fail "files differ from what the inline parser wrote (tests/fixtures/ledger/zero/files.dump)"
# One debug line more: the shared parser logs its manufacturer fill (the file
# is the same - status_candidate_seen wrote that text inline too).
FILL='[wmbus-bridge] [DIAG] candidate 52632878: updated manufacturer text from LISTEN block to (QDS) Qundis, Germany (0x4493)'
[[ "$(grep -cxF "${FILL}" "${TMP}/log.sorted")" == 1 ]] || fail "the manufacturer fill was not logged once"
diff -u "${GOLDEN}/log.sorted" <(grep -vxF "${FILL}" "${TMP}/log.sorted") >&2 \
  || fail "log lines differ from what the inline parser logged (tests/fixtures/ledger/zero/log.sorted)"
# The inline parser handed every new candidate to bash (handovers.new);
# python3 now registers and announces them itself, in the same order.
diff -u <(awk '{ print $2 }' "${GOLDEN}/handovers.new") "${TMP}/announced.new" >&2 \
  || fail "new candidates are not announced as the inline parser announced them"
[[ ! -s "${TMP}/handovers.new" ]] \
  || { cat "${TMP}/handovers.new" >&2; fail "new candidates were handed to bash"; }
# The inline parser handed every block to bash; known ones no longer go there.
[[ ! -s "${TMP}/handovers.known" ]] \
  || { cat "${TMP}/handovers.known" >&2; fail "known candidates were handed to bash"; }
# The preview change, the unannounced candidate and the type and driver
# changes: booked in python3 (the dump above holds what bash wrote).
[[ ! -s "${TMP}/handovers.changed" ]] \
  || { cat "${TMP}/handovers.changed" >&2; fail "changed candidates were handed to bash"; }

# ── 0 -> 1 meter: every block booked once ───────────────────────────────────
# The main instance's parser (zero) and the parallel LISTEN one (nonzero) see
# the same telegrams; the count file decides per block which one books it.
both() {  # both <offset>: the same corpus through both parsers
  ( export LEDGER_TEST_EPOCH=$(( T0 + $1 )) PYTHONPATH="${TMP}/clock"
    set +eu
    _listen_parse_stage zero < "${CORPUS}"
    _listen_parse_stage < "${CORPUS}" ) >/dev/null 2>&1 || true
}
seed
both 0                                                   # 0 meters: main books
printf '1\n' > "${STATUS_OFFICIAL_METERS_COUNT_FILE}"
both 5                                                   # 1 meter: LISTEN books
[[ "$(grep -c $'^24271170\tcandidate\t' "${STATUS_SEEN_FILE}")" == 2 ]] \
  || fail "0 -> 1 meter: 24271170 booked $(grep -c $'^24271170\tcandidate\t' "${STATUS_SEEN_FILE}") times in two batches, expected 2"
[[ "$(awk -F '\t' '$1 == "24271170" { print $5 }' "${STATUS_CANDIDATES_FILE}")" == 2 ]] \
  || fail "0 -> 1 meter: the candidate count of 24271170 is not 2"

echo "PASS: zero-meter listen output via bridge_ledger.py matches the inline parser (files, log, new candidates), known blocks stay in python3, 0 -> 1 meter books each block once"
