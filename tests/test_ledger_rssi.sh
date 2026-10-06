#!/usr/bin/env bash
# Regression test: the rssi/<id> subscriber booked by bridge_ledger.py.
#
# 1. Equivalence: the corpus through `bridge_ledger.py rssi` must leave the
#    status_rssi.tsv the former bash handler (_esp_rssi_handle_message) wrote
#    for it, apart from the receive time. That output was recorded before the
#    bash handler was removed: tests/fixtures/ledger/rssi/status_rssi.tsv.
#    inject_rssi_into_json reads this file for every decoded telegram, so a
#    different row would change what Home Assistant gets.
# 2. Restart: the real subscriber loop (_esp_rssi_subscriber) runs against a
#    stub broker, with SIGPIPE ignored; python3 is killed in the middle of the
#    stream. The loop must stop the subscription and start both again, and
#    only the message being handled at that moment may be lost - like a
#    dropped broker connection today.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/rootfs/usr/bin/bridge-lib"
BRIDGE_LEDGER="${ROOT}/rootfs/usr/bin/bridge_ledger.py"
# shellcheck source=rootfs/usr/bin/bridge-lib/01-utils.sh
source "${LIB}/01-utils.sh"
# shellcheck source=rootfs/usr/bin/bridge-lib/13-esp.sh
source "${LIB}/13-esp.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || fail "missing python3"
command -v flock >/dev/null 2>&1 || fail "missing flock"

TMP="$(mktemp -d)"
SUB_PID=""
cleanup() {
  local rc=$?
  if [[ -n "${SUB_PID}" ]]; then
    pkill -KILL -P "${SUB_PID}" 2>/dev/null || true
    kill -KILL "${SUB_PID}" 2>/dev/null || true
    wait "${SUB_PID}" 2>/dev/null || true
  fi
  # What the subscriber and python3 reported, to explain a failure.
  if (( rc != 0 )) && [[ -s "${TMP}/subscriber.err" ]]; then
    cat "${TMP}/subscriber.err" >&2
  fi
  rm -rf "${TMP}"
}
trap cleanup EXIT

# Configured meters. Only complete id= lines count: a trailing space, or a last
# line without a newline, is not an id for the bash reader either.
METER_DIR="${TMP}/meters"
mkdir -p "${METER_DIR}"
printf 'name=water\nid=52632878\ndriver=auto\n' > "${METER_DIR}/meter-0001"
printf 'id=abcdef12\n' > "${METER_DIR}/meter-0002"
printf 'id=11111111 \n' > "${METER_DIR}/meter-0003"
printf 'id=22222222' > "${METER_DIR}/meter-0004"

# ── 1. equivalence ──────────────────────────────────────────────────────────
CORPUS="${TMP}/corpus"
{
  printf 'wmbus/lilygo/rssi/52632878\t-70\n'
  printf 'wmbus/heltec/rssi/52632878\t-81\n'
  printf 'wmbus/lilygo/rssi/52632878\t-66\n'           # same board: replaced
  printf 'wmbus/lilygo/rssi/abcdef12\t-55\n'           # id from a lowercase meter file
  printf 'wmbus/heltec/rssi/ABCDEF12\t-56\n'
  printf 'wmbus/lilygo/rssi/77665544\t-60\n'           # not configured
  printf 'wmbus/lilygo/rssi/11111111\t-60\n'           # id line with trailing space
  printf 'wmbus/lilygo/rssi/22222222\t-60\n'           # id line without newline
  printf 'wmbus/lilygo/rssi/52632878\t-127\n'          # firmware sentinels
  printf 'wmbus/lilygo/rssi/52632878\t0\n'
  printf 'wmbus/lilygo/rssi/52632878\t1\n'
  printf 'wmbus/lilygo/rssi/52632878\tabc\n'
  printf 'wmbus/lilygo/rssi/52632878\t-126\n'
  printf 'wmbus/octal/rssi/52632878\t-070\n'           # bash reads octal: -56, stored as sent
  printf 'wmbus/octal9/rssi/52632878\t-089\n'          # invalid octal: rejected
  printf 'wmbus/xiao-seed/rssi/52632878\t-90\n'
  printf 'other/x/rssi/52632878\t-91\n'                # no wmbus/ prefix
  printf 'wmbus/a/rssi/b/rssi/52632878\t-92\n'         # two /rssi/ segments
  printf 'wmbus/lilygo/rssi/5263287\t-66\n'            # 7 hex digits
  printf 'wmbus/lilygo/rssi/526328781\t-66\n'          # 9 hex digits
  printf '\twmbus/tab/rssi/52632878\t-93\n'            # leading tab
  printf 'wmbus/tabs/rssi/52632878\t\t-94\n'           # run of tabs
  printf 'wmbus/empty/rssi/52632878\t\n'               # no payload
  printf 'wmbus/space/rssi/52632878\t-70 \n'           # trailing space
} > "${CORPUS}"
SEED=$'52632878\t-50\tolddev\t100\n99999999\t-40\tlilygo\t100\n'

GOLDEN="${ROOT}/tests/fixtures/ledger/rssi/status_rssi.tsv"
PY_OUT="${TMP}/py/status_rssi.tsv"
mkdir -p "${TMP}/py"
printf '%s' "${SEED}" > "${PY_OUT}"
python3 "${BRIDGE_LEDGER}" rssi --meter-dir "${METER_DIR}" --rssi-file "${PY_OUT}" < "${CORPUS}"

# The receive time is the only column allowed to differ.
normalize() { awk -F '\t' -v OFS='\t' '$4 > 1000000000 { $4 = "NOW" } { print }' "$1"; }
if ! diff -u "${GOLDEN}" <(normalize "${PY_OUT}"); then
  fail "bridge_ledger.py rssi wrote different rows than the recorded bash handler"
fi
[[ "$(wc -l < "${PY_OUT}" | tr -d ' ')" -ge 8 ]] || fail "equivalence corpus stored too few rows to mean anything"

# ── 2. restart after python3 dies ───────────────────────────────────────────
# The loop runs `${STDBUF_BIN} /usr/bin/mosquitto_sub ...`, so STDBUF_BIN can
# stand in for the broker: this stub ignores its arguments and replays the
# queue one message at a time, resuming where the previous connection stopped.
QUEUE="${TMP}/queue"
mkdir -p "${QUEUE}"
MESSAGES=40
for (( i = 1; i <= MESSAGES; i++ )); do
  printf 'wmbus/board%02d/rssi/52632878\t-%d\n' "${i}" $(( 40 + i ))
done > "${QUEUE}/messages"
echo 0 > "${QUEUE}/next"
cat > "${TMP}/broker-stub" <<'STUB'
#!/usr/bin/env bash
n="$(cat "${STUB_QUEUE}/next")"
total="$(wc -l < "${STUB_QUEUE}/messages")"
while (( n < total )); do
  line="$(sed -n "$(( n + 1 ))p" "${STUB_QUEUE}/messages")"
  n=$(( n + 1 ))
  echo "${n}" > "${STUB_QUEUE}/next"
  printf '%s\n' "${line}"
  sleep 0.05
done
STUB
chmod +x "${TMP}/broker-stub"
export STUB_QUEUE="${QUEUE}"

STATUS_RSSI_FILE="${TMP}/live/status_rssi.tsv"
mkdir -p "${TMP}/live"
: > "${STATUS_RSSI_FILE}"
STDBUF_BIN="${TMP}/broker-stub"
SUB_ARGS=()
_sub_reconnect_sleep() { sleep 0.2; }

rows() { wc -l < "${STATUS_RSSI_FILE}" | tr -d ' '; }
rows_at_least() { (( $(rows) >= $1 )); }
queue_sent() {  # the stub rewrites the counter, so it can read empty for a moment
  local n
  n="$(cat "${QUEUE}/next")"
  [[ "${n}" =~ ^[0-9]+$ ]] && (( n >= MESSAGES ))
}
wait_for() {  # wait_for <seconds> <predicate...>; the predicate is re-run each time
  local deadline=$(( SECONDS + $1 )); shift
  until "$@"; do (( SECONDS < deadline )) || return 1; sleep 0.1; done
}

# SIGPIPE ignored, the worst case and how GitHub's runners start jobs: a dead
# reader then does not stop the writer, so the loop itself has to.
( trap '' PIPE; _esp_rssi_subscriber ) 2>"${TMP}/subscriber.err" &
SUB_PID=$!

wait_for 15 rows_at_least 10 || fail "restart: python3 never booked the first messages"
pkill -KILL -f "${BRIDGE_LEDGER} rssi --meter-dir ${METER_DIR}" \
  || fail "restart: no bridge_ledger.py process to kill"
killed_after="$(rows)"

wait_for 30 queue_sent \
  || fail "restart: the loop did not reconnect after python3 died (stopped at message $(cat "${QUEUE}/next"))"
# Wait for the last message itself, not for MESSAGES-1 rows: when the kill
# happens to lose nothing, MESSAGES-1 rows exist while the last one is still
# on its way, and the check below would race it.
last_booked() { grep -q $'^52632878\t-80\tboard40\t' "${STATUS_RSSI_FILE}"; }
wait_for 10 last_booked || true

final="$(rows)"
last_booked \
  || fail "restart: the last message was not booked - python3 was not started again"
(( final > killed_after )) || fail "restart: nothing booked after python3 was killed"
(( final >= MESSAGES - 1 )) \
  || fail "restart: ${final} of ${MESSAGES} messages booked; more than the one in flight was lost"
leftovers="$(find "${TMP}/live" -name '*.tmp.*')"
[[ -z "${leftovers}" ]] || fail "restart: temporary files left behind: ${leftovers}"

echo "PASS: rssi via bridge_ledger.py matches the recorded bash output and survives python3 dying (${final}/${MESSAGES} booked)"
