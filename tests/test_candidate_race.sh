#!/usr/bin/env bash
# Regression test: concurrent writes to status_candidates.tsv must not lose rows.
#
# Simulates corpus replay at 5 s interval (many parallel writers across primary
# LISTEN, parallel LISTEN, JSON update, RAW fallback, SEARCH paths).
#
# Pass criteria:
#   - candidate list grows monotonically (no previously detected ID disappears)
#   - each ID appears exactly once (no duplicates, no lost writes)
#   - subsequent telegrams for the same ID update the existing row in place
#
# Run: bash tests/test_candidate_race.sh
# Requires: bash 4+, flock (util-linux), awk, mktemp  — all present on Linux.
set -euo pipefail

PASS=0
FAIL=0

pass() { echo "PASS: $*"; PASS=$(( PASS + 1 )); }
fail() { echo "FAIL: $*" >&2; FAIL=$(( FAIL + 1 )); }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

STATUS_CANDIDATES_FILE="${WORKDIR}/status_candidates.tsv"
touch "${STATUS_CANDIDATES_FILE}"

# ── Inline _tsv_upsert (identical to bridge.sh) ──────────────────────────────
_tsv_upsert() {
  local file="$1" id="$2" row="$3"
  (
    flock -x 9
    local _tmp
    _tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
    awk -F '\t' -v id="${id}" '$1 != id {print}' "${file}" 2>/dev/null > "${_tmp}" || true
    printf '%s\n' "${row}" >> "${_tmp}"
    mv "${_tmp}" "${file}" 2>/dev/null || { rm -f "${_tmp}"; true; }
  ) 9>"${file}.lock"
}

# Simulated status_candidate_seen (stripped: no wmbusmeters, no events, no JSON)
write_candidate() {
  local id="$1" driver="${2:-auto}"
  _tsv_upsert "${STATUS_CANDIDATES_FILE}" "${id}" \
    "$(printf '%s\t%s\ttesttype\t2026-01-01T00:00:00Z\t1\t0\t0\t0' "${id}" "${driver}")"
}

count_rows() { wc -l < "${STATUS_CANDIDATES_FILE}" | tr -d ' '; }
count_dupes() { cut -f1 "${STATUS_CANDIDATES_FILE}" | sort | uniq -d | wc -l | tr -d ' '; }

# ── Test 1: 20 unique IDs × 3 concurrent writers each ────────────────────────
# Simulates primary LISTEN + parallel LISTEN + JSON update hitting the same file.
echo "--- Test 1: 20 IDs × 3 parallel writers (primary/parallel LISTEN + JSON) ---"
PIDS=()
for i in $(seq 1 20); do
  id="$(printf 'AABBCC%02d' "${i}")"
  write_candidate "${id}" "auto"   & PIDS+=($!)
  write_candidate "${id}" "izarv2" & PIDS+=($!)
  write_candidate "${id}" "diehl"  & PIDS+=($!)
done
wait "${PIDS[@]}" 2>/dev/null || true

n=$(count_rows)
if [[ "${n}" -eq 20 ]]; then
  pass "Test 1: 20 unique IDs → ${n} rows (no lost writes, no duplicates at row level)"
else
  fail "Test 1: expected 20 rows, got ${n}; IDs present: $(cut -f1 "${STATUS_CANDIDATES_FILE}" | sort | tr '\n' ' ')"
fi

d=$(count_dupes)
if [[ "${d}" -eq 0 ]]; then
  pass "Test 1: no duplicate IDs"
else
  fail "Test 1: ${d} duplicate ID(s) found: $(cut -f1 "${STATUS_CANDIDATES_FILE}" | sort | uniq -d | tr '\n' ' ')"
fi

# ── Test 2: Monotonic growth — pre-existing rows never disappear ──────────────
# Simulates corpus replay adding new candidates while existing ones are updated.
echo "--- Test 2: Monotonic growth under concurrent additions + re-updates ---"
mapfile -t INITIAL_IDS < <(cut -f1 "${STATUS_CANDIDATES_FILE}")

PIDS=()
for i in $(seq 21 30); do
  id="$(printf 'AABBCC%02d' "${i}")"
  write_candidate "${id}" "auto" & PIDS+=($!)
done
for i in $(seq 1 10); do
  id="$(printf 'AABBCC%02d' "${i}")"
  write_candidate "${id}" "updated" & PIDS+=($!)
done
wait "${PIDS[@]}" 2>/dev/null || true

missing=0
for id in "${INITIAL_IDS[@]}"; do
  if ! grep -q "^${id}	" "${STATUS_CANDIDATES_FILE}" 2>/dev/null; then
    fail "Test 2: ID ${id} disappeared from the list"
    missing=$(( missing + 1 ))
  fi
done
if [[ "${missing}" -eq 0 ]]; then
  pass "Test 2: all ${#INITIAL_IDS[@]} initial IDs still present after concurrent additions"
fi

n2=$(count_rows)
if [[ "${n2}" -eq 30 ]]; then
  pass "Test 2: final count = 30 (grew from 20, monotonically)"
else
  fail "Test 2: expected 30 rows, got ${n2}"
fi

# ── Test 3: Single ID updated repeatedly — always exactly one row ─────────────
# Simulates many telegrams from the same meter (ID must not accumulate rows).
echo "--- Test 3: Same ID written 50 times concurrently — exactly 1 row expected ---"
SINGLE_ID="DEADBEEF"
PIDS=()
for _ in $(seq 1 50); do
  write_candidate "${SINGLE_ID}" "auto" & PIDS+=($!)
done
wait "${PIDS[@]}" 2>/dev/null || true

single_count=$(grep -c "^${SINGLE_ID}	" "${STATUS_CANDIDATES_FILE}" 2>/dev/null || echo 0)
if [[ "${single_count}" -eq 1 ]]; then
  pass "Test 3: ID ${SINGLE_ID} appears exactly 1 time after 50 concurrent writes"
else
  fail "Test 3: ID ${SINGLE_ID} appears ${single_count} times (expected 1)"
fi

# ── Test 4: Stress — 200 rapid writes across 20 IDs (corpus at 5 s interval) ─
echo "--- Test 4: Stress — 200 rapid writes × 20 IDs (5 s replay simulation) ---"
rm -f "${STATUS_CANDIDATES_FILE}"
touch "${STATUS_CANDIDATES_FILE}"

PIDS=()
for _ in {1..10}; do
  for i in $(seq 1 20); do
    id="$(printf 'DDEEFF%02d' "${i}")"
    write_candidate "${id}" "auto" & PIDS+=($!)
  done
done
wait "${PIDS[@]}" 2>/dev/null || true

n4=$(count_rows)
if [[ "${n4}" -eq 20 ]]; then
  pass "Test 4: 200 writes × 20 IDs → ${n4} rows (correct)"
else
  fail "Test 4: expected 20 rows, got ${n4}"
fi

d4=$(count_dupes)
if [[ "${d4}" -eq 0 ]]; then
  pass "Test 4: no duplicate IDs after stress"
else
  fail "Test 4: ${d4} duplicate ID(s) after stress"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]] || exit 1
