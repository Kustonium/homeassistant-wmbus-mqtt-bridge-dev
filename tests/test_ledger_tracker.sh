#!/usr/bin/env bash
# Regression test: the per-ESP /telegram tracker booked by bridge_ledger.py.
#
# The tracker sees every RAW telegram from every board and writes which board
# is alive (status_esp_telegram_devices.tsv), which board delivered which meter
# (status_esp_meter_device.tsv), per-board reception counts
# (status_esp_meter_reception.tsv) and a bounded history (esp_rx_history.jsonl).
# bridge_ledger.py replaced the bash handler (_esp_tracker_handle_message), so
# it must produce the same bytes:
#   1. a hand-written corpus of awkward messages,
#   2. 200 generated messages built from the fixture frames,
# each through `bridge_ledger.py tracker`, all four files compared with what
# the bash handler wrote for the same corpus - recorded before it was removed,
# in tests/fixtures/ledger/tracker/<corpus>/;
#   3. the real subscriber loop against a stub broker, with SIGPIPE ignored,
# python3 stopped (SIGTERM) mid-stream: the loop must start it again and only the message
# being handled may be lost.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/rootfs/usr/bin/bridge-lib"
BRIDGE_LEDGER="${ROOT}/rootfs/usr/bin/bridge_ledger.py"
FIXTURES="${ROOT}/tests/fixtures"
# shellcheck source=rootfs/usr/bin/bridge-lib/00-logging.sh
source "${LIB}/00-logging.sh"
# shellcheck source=rootfs/usr/bin/bridge-lib/01-utils.sh
source "${LIB}/01-utils.sh"
# shellcheck source=rootfs/usr/bin/bridge-lib/03-tsv.sh
source "${LIB}/03-tsv.sh"
# shellcheck source=rootfs/usr/bin/bridge-lib/05-raw.sh
source "${LIB}/05-raw.sh"
# shellcheck source=rootfs/usr/bin/bridge-lib/13-esp.sh
source "${LIB}/13-esp.sh"
log() { :; }

fail() { echo "FAIL: $*" >&2; exit 1; }
for _bin in python3 jq flock awk; do
  command -v "${_bin}" >/dev/null 2>&1 || fail "missing ${_bin}"
done

TMP="$(mktemp -d)"
SUB_PID=""
cleanup() {
  local rc=$?
  if [[ -n "${SUB_PID}" ]]; then
    pkill -KILL -P "${SUB_PID}" 2>/dev/null || true
    kill -KILL "${SUB_PID}" 2>/dev/null || true
    wait "${SUB_PID}" 2>/dev/null || true
  fi
  if (( rc != 0 )) && [[ -s "${TMP}/subscriber.err" ]]; then
    cat "${TMP}/subscriber.err" >&2
  fi
  rm -rf "${TMP}"
}
trap cleanup EXIT

FILES=(devices meter_device reception history)
QWATER="$(tr -d '[:space:]' < "${FIXTURES}/qwaterv2/52632878.hex")"
OTHER="${QWATER:0:8}44556677${QWATER:16}"

# Starting files of one side: rows to keep, to count on from (written with a
# leading zero, which stays unless the count changes), and a row with too few
# fields.
seed() {
  local d="$1"
  mkdir -p "${d}"
  printf 'olddev\t100\twmbus/olddev/telegram\t007\nheltec\t100\twmbus/heltec/telegram\n' > "${d}/devices"
  printf '52632878\tolddev\t100\n99999999\tlilygo\t100\n' > "${d}/meter_device"
  printf '52632878\tolddev\t100\t200\t007\twmbus/olddev/telegram\n' > "${d}/reception"
  : > "${d}/history"
}

run_python() {  # run_python <dir> <corpus>
  python3 "${BRIDGE_LEDGER}" tracker --dev-pos 1 \
    --devices-file "$1/devices" --meter-device-file "$1/meter_device" \
    --reception-file "$1/reception" --history-file "$1/history" < "$2"
}

# Receive times become NOW; every other byte must match. The recorded files
# went through the same normalisation.
normalize() {  # normalize <file> <kind> <since-epoch>
  case "$2" in
    history) sed -E 's/"time":[0-9]+/"time":"NOW"/' "$1" ;;
    *) awk -F '\t' -v OFS='\t' -v t="$3" '{ for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/ && $i >= t) $i = "NOW"; print }' "$1" ;;
  esac
}

compare() {  # compare <label> <corpus>
  local label="$1" corpus="$2" since f
  rm -rf "${TMP}/py"
  seed "${TMP}/py"
  since="$(date +%s)"
  run_python "${TMP}/py" "${corpus}"
  for f in "${FILES[@]}"; do
    if ! diff -u "${ROOT}/tests/fixtures/ledger/tracker/${label}/${f}" \
                 <(normalize "${TMP}/py/${f}" "${f}" "${since}") >"${TMP}/diff"; then
      cat "${TMP}/diff" >&2
      fail "${label}: ${f} differs from what the bash handler wrote (tests/fixtures/ledger/tracker/${label})"
    fi
  done
  [[ -s "${TMP}/py/history" ]] || fail "${label}: nothing was booked - the corpus tests nothing"
  return 0
}

# ── 1. hand-written corpus ──────────────────────────────────────────────────
CORPUS="${TMP}/corpus"
{
  printf 'wmbus/lilygo/telegram\t%s\n' "${QWATER}"
  printf 'wmbus/heltec/telegram\t%s\n' "${QWATER}"         # seeded row with 3 fields
  printf 'wmbus/lilygo/telegram\t%s\n' "${QWATER}"         # same board again: no meter-device rewrite
  printf 'wmbus/olddev/telegram\t%s\n' "${QWATER}"         # seeded count 007
  printf 'wmbus/lilygo/telegram\t%s\n' "${QWATER}"         # meter moves back
  printf 'wmbus/lilygo/telegram\t%s\n' "${OTHER}"
  printf 'wmbus/lilygo/telegram\t %s \n' "${QWATER,,}"      # lower case, spaces
  printf 'wmbus/lilygo/telegram\t%s\t%s\n' "${QWATER:0:20}" "${QWATER:20}"  # tab inside the payload
  printf 'wmbus/lilygo/telegram\t%s\n' "${QWATER:0:40}"    # L-field does not match: board counted, no meter
  printf 'wmbus/lilygo/telegram\tZZZZ\n'
  printf 'wmbus/lilygo/telegram\t\n'
  printf 'wmbus/izar/telegram\t%s\n' "$(tr -d '[:space:]' < "${FIXTURES}/izar/2156B4C2.hex")"
  printf 'wmbus//telegram\t%s\n' "${QWATER}"               # no board name
  printf 'wmbus\t%s\n' "${QWATER}"                         # no board segment at all
  printf 'wmbus/trailing/\t%s\n' "${QWATER}"
  printf 'wmbus/a/b/c/telegram\t%s\n' "${QWATER}"
  printf 'wmbus/xiao-seed/telegram\t%s\n' "${QWATER}"
  printf 'wmbus/q"uote/telegram\t%s\n' "${OTHER}"          # escaped in the JSON history
} > "${CORPUS}"
compare "corpus" "${CORPUS}"

# ── 2. generated messages ───────────────────────────────────────────────────
python3 - "${FIXTURES}" "${TMP}/generated" <<'PY'
import glob, os, random, sys
fixtures, out_path = sys.argv[1:3]
rnd = random.Random(20261002)
frames = []
for path in sorted(glob.glob(os.path.join(fixtures, "*", "*.hex"))):
    with open(path) as fh:
        frames.append("".join(fh.read().split()))
def mutate(frame):
    roll = rnd.random()
    if roll < 0.6:
        return frame
    if roll < 0.7:
        return frame.lower()
    if roll < 0.8:  # another meter id in the A-field
        return frame[:8] + "%08X" % rnd.randrange(1 << 32) + frame[16:]
    if roll < 0.85:
        return frame[:-2]  # L-field no longer matches
    if roll < 0.9:
        return " " + frame + " "
    if roll < 0.95:
        return frame[:-1]  # odd length
    return "XYZ"
# No two boards that awk would compare as equal numbers (the deliberate
# difference pinned in tests/test_bridge_ledger.py).
boards = ["lilygo", "heltec", "xiao-seed", "1E3", "board5"]
with open(out_path, "w") as out:
    for _ in range(200):
        out.write("wmbus/%s/telegram\t%s\n" % (rnd.choice(boards), mutate(rnd.choice(frames))))
PY
compare "generated" "${TMP}/generated"
booked="$(wc -l < "${TMP}/py/history" | tr -d ' ')"
(( booked >= 100 )) || fail "generated: only ${booked} of 200 messages carried a meter id - the generator tests too little"

# ── 3. restart after python3 dies ───────────────────────────────────────────
QUEUE="${TMP}/queue"
mkdir -p "${QUEUE}"
MESSAGES=40
for (( i = 1; i <= MESSAGES; i++ )); do
  printf 'wmbus/board%02d/telegram\t%s\n' "${i}" "${QWATER}"
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
# Like the real subscription (no -W), stay connected once the queue is empty.
sleep 60
STUB
chmod +x "${TMP}/broker-stub"
export STUB_QUEUE="${QUEUE}"

LIVE="${TMP}/live"
mkdir -p "${LIVE}"
STATUS_ESP_TELEGRAM_DEVICES_FILE="${LIVE}/devices"
STATUS_ESP_METER_DEVICE_FILE="${LIVE}/meter_device"
STATUS_ESP_METER_RECEPTION_FILE="${LIVE}/reception"
ESP_RX_HISTORY_FILE="${LIVE}/history"
: > "${STATUS_ESP_TELEGRAM_DEVICES_FILE}"
: > "${STATUS_ESP_METER_DEVICE_FILE}"
: > "${ESP_RX_HISTORY_FILE}"
RAW_TOPIC="wmbus/+/telegram"
STDBUF_BIN="${TMP}/broker-stub"
SUB_ARGS=()
SUB_EXTRA=()
_sub_reconnect_sleep() { sleep 0.2; }

boards_seen() { wc -l < "${STATUS_ESP_TELEGRAM_DEVICES_FILE}" | tr -d ' '; }
boards_at_least() { (( $(boards_seen) >= $1 )); }
queue_sent() {
  local n
  n="$(cat "${QUEUE}/next")"
  [[ "${n}" =~ ^[0-9]+$ ]] && (( n >= MESSAGES ))
}
wait_for() {  # wait_for <seconds> <predicate...>
  local deadline=$(( SECONDS + $1 )); shift
  until "$@"; do (( SECONDS < deadline )) || return 1; sleep 0.1; done
}

# SIGPIPE ignored: the worst case, and how GitHub's runners start jobs.
( trap '' PIPE; _esp_tracker_subscriber ) 2>"${TMP}/subscriber.err" &
SUB_PID=$!

sent_at_least() { local n; n="$(cat "${QUEUE}/next")"; [[ "${n}" =~ ^[0-9]+$ ]] && (( n >= $1 )); }
# The rows are written every few seconds, so the kill is timed by what the
# stub has sent; the stopped process writes what it collected.
wait_for 15 sent_at_least 10 || fail "restart: python3 never received the first messages"
# SIGTERM, what stopping the add-on sends: the collected writes are made
# before python3 exits.
pkill -TERM -f "${BRIDGE_LEDGER} tracker --dev-pos 1 --devices-file ${LIVE}/devices" \
  || fail "restart: no bridge_ledger.py tracker process to kill"
killed_after="$(cat "${QUEUE}/next")"
wait_for 30 queue_sent \
  || fail "restart: the loop did not reconnect after python3 died (stopped at message $(cat "${QUEUE}/next"))"
# Wait for the last message itself, not for MESSAGES-1 boards: when the kill
# happens to lose nothing, MESSAGES-1 boards exist while the last one is still
# on its way, and the check below would race it.
last_booked() { grep -q "^board${MESSAGES}"$'\t' "${STATUS_ESP_TELEGRAM_DEVICES_FILE}"; }
wait_for 10 last_booked || true

final="$(boards_seen)"
last_booked \
  || fail "restart: the last message was not booked - python3 was not started again"
(( final > killed_after )) || fail "restart: nothing booked after python3 was killed"
(( final >= MESSAGES - 1 )) \
  || fail "restart: ${final} of ${MESSAGES} messages booked; more than the one in flight was lost"
leftovers="$(find "${LIVE}" -name '*.tmp*')"
[[ -z "${leftovers}" ]] || fail "restart: temporary files left behind: ${leftovers}"

# ── python3 killed hard (SIGKILL) mid-stream ────────────────────────────────
# What was collected since the last write is lost (up to 5 s of counters);
# the files must stay whole and the restarted process must go on.
# Integrity of the state files after python3 was killed hard: each file is
# there, not empty, ends with a newline and every row has its fields (TSV) or
# is one JSON value (JSONL). Counters may lag by up to 5 s; that is accepted.
check_tsv() {  # check_tsv <file> <fields>
  [[ -s "$1" ]] || fail "SIGKILL: ${1##*/} is empty or missing"
  [[ "$(tail -c 1 "$1" | wc -l)" == 1 ]] || fail "SIGKILL: ${1##*/} is cut off (no final newline)"
  awk -F '\t' -v n="$2" 'NF != n { bad = 1 } END { exit bad }' "$1" \
    || fail "SIGKILL: ${1##*/} has a row without its ${2} fields"
}
check_jsonl() {  # check_jsonl <file>
  [[ -s "$1" ]] || fail "SIGKILL: ${1##*/} is empty or missing"
  [[ "$(tail -c 1 "$1" | wc -l)" == 1 ]] || fail "SIGKILL: ${1##*/} is cut off (no final newline)"
  while IFS= read -r line; do
    jq -e . <<< "${line}" >/dev/null 2>&1 || fail "SIGKILL: ${1##*/} has a line that is not JSON"
  done < "$1"
}
pkill -KILL -P "${SUB_PID}" 2>/dev/null || true
kill -KILL "${SUB_PID}" 2>/dev/null || true
wait "${SUB_PID}" 2>/dev/null || true
pkill -KILL -f "${BRIDGE_LEDGER} tracker --dev-pos 1 --devices-file ${LIVE}/devices" 2>/dev/null || true
for (( i = MESSAGES + 1; i <= 2 * MESSAGES; i++ )); do
  printf 'wmbus/board%02d/telegram\t%s\n' "${i}" "${QWATER}"
done >> "${QUEUE}/messages"
MESSAGES=$(( 2 * MESSAGES ))
( trap '' PIPE; _esp_tracker_subscriber ) 2>>"${TMP}/subscriber.err" &
SUB_PID=$!
wait_for 15 sent_at_least $(( MESSAGES - 20 )) || fail "SIGKILL: the subscriber did not start again"
pkill -KILL -f "${BRIDGE_LEDGER} tracker --dev-pos 1 --devices-file ${LIVE}/devices" \
  || fail "SIGKILL: no bridge_ledger.py tracker process to kill"
wait_for 30 queue_sent || fail "SIGKILL: the loop did not reconnect after python3 was killed"
wait_for 10 last_booked || fail "SIGKILL: the restarted process did not book the last message"
check_tsv "${STATUS_ESP_TELEGRAM_DEVICES_FILE}" 4
check_tsv "${STATUS_ESP_METER_DEVICE_FILE}" 3
check_tsv "${STATUS_ESP_METER_RECEPTION_FILE}" 6
check_jsonl "${ESP_RX_HISTORY_FILE}"
leftovers="$(find "${LIVE}" -name '*.tmp*')"
[[ -z "${leftovers}" ]] || fail "SIGKILL: temporary files left behind: ${leftovers}"

echo "PASS: tracker via bridge_ledger.py matches the recorded bash output (corpus + 200 generated, ${booked} with a meter id) and survives python3 stopped (${final}/40 booked) and killed (files whole)"
