#!/usr/bin/env bash
# Regression test: bridge_ledger.py and the bash helpers share their locks.
#
# While per-message bookkeeping moves to bridge_ledger.py one path at a time,
# bash keeps writing some of the same files (the decode loop, the LISTEN path,
# the tickers). Both sides must serialise on "<file>.lock": flock(1) in bash,
# fcntl.flock() in Python. If they did not, a read-modify-write from one side
# would silently drop the row the other side had just written - no error, just
# a candidate or a reading that vanishes. This test runs both writers at once
# on one file and counts every row.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=rootfs/usr/bin/bridge-lib/03-tsv.sh
source "${ROOT}/rootfs/usr/bin/bridge-lib/03-tsv.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || fail "missing python3"
command -v flock >/dev/null 2>&1 || fail "missing flock"
command -v jq >/dev/null 2>&1 || fail "missing jq"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

WORKERS=3
ROUNDS=40
PY_LIB="${ROOT}/rootfs/usr/bin"

# ── keyed upserts from both sides ───────────────────────────────────────────
# Every worker writes its own keys and also rewrites one shared key on every
# round, so the two sides constantly read and replace the same file.
TSV="${TMP}/shared.tsv"
: > "${TSV}"

bash_upserts() {
  local w="$1" i
  for (( i = 0; i < ROUNDS; i++ )); do
    _tsv_upsert "${TSV}" "B${w}K${i}" "$(printf 'B%sK%s\tbash' "${w}" "${i}")"
    _tsv_upsert "${TSV}" "SHARED" "$(printf 'SHARED\tbash%s-%s' "${w}" "${i}")"
  done
}

py_upserts() {
  python3 - "${PY_LIB}" "${TSV}" "$1" "${ROUNDS}" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import bridge_ledger as bl
path, w, rounds = sys.argv[2], sys.argv[3], int(sys.argv[4])
for i in range(rounds):
    bl.tsv_upsert(path, f"P{w}K{i}", f"P{w}K{i}\tpython")
    bl.tsv_upsert(path, "SHARED", f"SHARED\tpython{w}-{i}")
PY
}

pids=()
for (( w = 0; w < WORKERS; w++ )); do
  bash_upserts "${w}" & pids+=("$!")
  py_upserts "${w}" & pids+=("$!")
done
for pid in "${pids[@]}"; do wait "${pid}" || fail "an upsert worker failed"; done

expected=$(( 2 * WORKERS * ROUNDS + 1 ))
[[ "$(wc -l < "${TSV}" | tr -d ' ')" == "${expected}" ]] \
  || fail "upserts: expected ${expected} rows, found $(wc -l < "${TSV}" | tr -d ' ') - a writer lost the other side's rows"
dupes="$(cut -f1 "${TSV}" | sort | uniq -d)"
[[ -z "${dupes}" ]] || fail "upserts: duplicated keys: ${dupes}"
for (( w = 0; w < WORKERS; w++ )); do
  for (( i = 0; i < ROUNDS; i++ )); do
    grep -q "^B${w}K${i}	bash$" "${TSV}" || fail "upserts: bash row B${w}K${i} lost"
    grep -q "^P${w}K${i}	python$" "${TSV}" || fail "upserts: python row P${w}K${i} lost"
  done
done

# ── locked appends from both sides ──────────────────────────────────────────
# The JSONL histories are appended under the same lock; interleaved writers
# must never split or merge a line.
JSONL="${TMP}/history.jsonl"
: > "${JSONL}"

bash_appends() {
  local w="$1" i
  for (( i = 0; i < ROUNDS; i++ )); do
    _append_esp_rx_history "${JSONL}" "${i}" "bash${w}" 52632878 wmbus/lilygo/telegram
  done
}

py_appends() {
  python3 - "${PY_LIB}" "${JSONL}" "$1" "${ROUNDS}" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import bridge_ledger as bl
path, w, rounds = sys.argv[2], sys.argv[3], int(sys.argv[4])
for i in range(rounds):
    bl.append_locked(path, json.dumps({"time": i, "source": f"python{w}",
                                       "meter_id": "52632878", "topic": "wmbus/lilygo/telegram"},
                                      separators=(",", ":")))
PY
}

pids=()
for (( w = 0; w < WORKERS; w++ )); do
  bash_appends "${w}" & pids+=("$!")
  py_appends "${w}" & pids+=("$!")
done
for pid in "${pids[@]}"; do wait "${pid}" || fail "an append worker failed"; done

expected=$(( 2 * WORKERS * ROUNDS ))
[[ "$(wc -l < "${JSONL}" | tr -d ' ')" == "${expected}" ]] \
  || fail "appends: expected ${expected} lines, found $(wc -l < "${JSONL}" | tr -d ' ')"
jq -e -s "length == ${expected}" "${JSONL}" >/dev/null \
  || fail "appends: a line is not valid JSON - writers interleaved inside a line"

# Nothing may be left behind by either side's temporary files.
leftovers="$(find "${TMP}" -name '*.tmp.*')"
[[ -z "${leftovers}" ]] || fail "temporary files left behind: ${leftovers}"

echo "PASS: bash and bridge_ledger.py serialise on the same locks (${WORKERS}+${WORKERS} writers, no row lost)"
