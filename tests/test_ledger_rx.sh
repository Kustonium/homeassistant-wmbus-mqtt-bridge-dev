#!/usr/bin/env bash
# Regression test: the wmbus/<board>/rx subscriber booked by bridge_ledger.py.
#
# The /rx handler writes six files the WebUI reads (reception, link mode,
# sequence continuity, boots, clock) or exports (esp_rf_rx_history.jsonl).
# bridge_ledger.py replaced the bash handler (_esp_rx_handle_message), which ran
# jq twice and six locked awk rewrites per message, so it must produce the same
# bytes:
#   1. a hand-written corpus of awkward messages,
#   2. 200 generated messages mixing valid and invalid field values,
# each through `bridge_ledger.py rx`, all six files compared with what the bash
# handler wrote for the same corpus - recorded before it was removed, in
# tests/fixtures/ledger/rx/<corpus>/;
#   3. the real subscriber loop against a stub broker, with SIGPIPE ignored,
# python3 stopped (SIGTERM) mid-stream: the loop must start it again and only the message
# being handled may be lost. This subscription has no -W timeout, so without
# that a dead python3 would stop /rx bookkeeping for good.
#
# The receive time and what is derived from it (clock skew) come from the
# clock, so they are compared as such; every other byte must match.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/rootfs/usr/bin/bridge-lib"
BRIDGE_LEDGER="${ROOT}/rootfs/usr/bin/bridge_ledger.py"
# shellcheck source=rootfs/usr/bin/bridge-lib/01-utils.sh
source "${LIB}/01-utils.sh"
# shellcheck source=rootfs/usr/bin/bridge-lib/13-esp.sh
source "${LIB}/13-esp.sh"

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

FILES=(reception mode history sequence boots clock)

# Files of one side in <dir>, seeded with rows the handlers must keep or
# update: values written with leading zeros stay as they are unless changed.
seed() {
  local d="$1"
  mkdir -p "${d}"
  printf '52632878\tolddev\t100\t200\t007\twmbus/olddev/rx\n' > "${d}/reception"
  printf '52632878\tC1\t007\t200\n' > "${d}/mode"
  : > "${d}/history"
  printf 'olddev\tAAAAAAAA\t0010\t003\t002\t200\n' > "${d}/sequence"
  printf 'olddev\tAAAAAAAA\t100\t200\t007\n' > "${d}/boots"
  printf 'olddev\t150\t200\t50\t007\t003\n' > "${d}/clock"
}

run_python() {  # run_python <dir> <corpus>
  python3 "${BRIDGE_LEDGER}" rx \
    --reception-file "$1/reception" --mode-file "$1/mode" --history-file "$1/history" \
    --sequence-file "$1/sequence" --boots-file "$1/boots" --clock-file "$1/clock" < "$2"
}

# Receive times become NOW, and so does a clock skew written in this run: it is
# the bridge time of the last stamped frame minus its stamp, so it depends on
# when the test runs. tests/test_bridge_ledger.py checks the skew itself with a
# fixed clock. The recorded files went through the same normalisation.
normalize() {  # normalize <file> <kind> <since-epoch>
  case "$2" in
    history)  # textually: re-serialising with jq would hide byte differences
      sed -E 's/"bridge_rx_time":[0-9]+/"bridge_rx_time":"NOW"/' "$1" ;;
    clock)
      awk -F '\t' -v OFS='\t' -v t="$3" '
        $3 >= t { if ($2 != 0) $4 = "SKEW"; $3 = "NOW" }
        { print }' "$1" ;;
    *)
      awk -F '\t' -v OFS='\t' -v t="$3" '{ for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/ && $i >= t) $i = "NOW"; print }' "$1" ;;
  esac
}

compare() {  # compare <label> <corpus>
  local label="$1" corpus="$2" since f
  rm -rf "${TMP}/py"
  seed "${TMP}/py"
  since="$(date +%s)"
  run_python "${TMP}/py" "${corpus}"
  for f in "${FILES[@]}"; do
    if ! diff -u "${ROOT}/tests/fixtures/ledger/rx/${label}/${f}" \
                 <(normalize "${TMP}/py/${f}" "${f}" "${since}") >"${TMP}/diff"; then
      cat "${TMP}/diff" >&2
      fail "${label}: ${f} differs from what the bash handler wrote (tests/fixtures/ledger/rx/${label})"
    fi
  done
  [[ -s "${TMP}/py/history" ]] || fail "${label}: nothing was booked - the corpus tests nothing"
  return 0
}

# ── 1. hand-written corpus ──────────────────────────────────────────────────
rx() {  # rx <topic> <json>
  printf '%s\t%s\n' "$1" "$2"
}
base='"schema":1,"rx_task_wakeup_us":123,"mode":"T1","frame_crc32":"7f56a83c","frame_length":123'
CORPUS="${TMP}/corpus"
{
  rx wmbus/lilygo/rx "{${base},\"boot_id\":\"a84f12c7\",\"seq\":1,\"meter_id\":\"52632878\",\"rssi_dbm\":-54,\"received_at\":\"2026-10-02T10:00:00.123Z\"}"
  rx wmbus/lilygo/rx "{${base},\"boot_id\":\"A84F12C7\",\"seq\":2,\"meter_id\":\"52632878\"}"
  rx wmbus/lilygo/rx "{${base},\"boot_id\":\"A84F12C7\",\"seq\":3,\"meter_id\":\"52632878\"}"
  rx wmbus/lilygo/rx "{${base},\"boot_id\":\"A84F12C7\",\"seq\":5,\"meter_id\":\"77665544\"}"      # gap
  rx wmbus/lilygo/rx "{${base},\"boot_id\":\"A84F12C7\",\"seq\":4,\"meter_id\":\"52632878\"}"      # late
  rx wmbus/lilygo/rx "{${base},\"boot_id\":\"A84F12C7\",\"seq\":4,\"meter_id\":\"52632878\"}"      # duplicate
  rx wmbus/lilygo/rx "{${base},\"boot_id\":\"651E6871\",\"seq\":1,\"meter_id\":\"52632878\"}"      # new boot, hex-looking id
  rx wmbus/heltec/rx "{${base},\"boot_id\":\"999E9999\",\"seq\":1,\"meter_id\":\"52632878\",\"mode\":\"C1\"}"
  rx wmbus/heltec/rx "{${base},\"boot_id\":\"999E9999\",\"seq\":7.0,\"meter_id\":\"52632878\",\"mode\":\"S1\"}"   # 7.0 is integral
  rx wmbus/heltec/rx "{${base},\"boot_id\":\"999E9999\",\"seq\":1e3,\"meter_id\":\"52632878\"}"   # printed as 1E+3
  rx wmbus/olddev/rx "{${base},\"boot_id\":\"AAAAAAAA\",\"seq\":12,\"meter_id\":\"52632878\",\"mode\":\"C1\"}"   # seeded rows
  rx wmbus/olddev/rx "{${base},\"boot_id\":\"AAAAAAAA\",\"seq\":9,\"meter_id\":\"52632878\",\"received_at\":\"2026-02-30T23:59:60.500Z\"}"
  rx wmbus/olddev/rx "{${base},\"boot_id\":\"AAAAAAAA\",\"seq\":12,\"meter_id\":\"52632878\"}"   # duplicate of the highest
  rx wmbus/clock/rx  "{${base},\"boot_id\":\"0000BEEF\",\"seq\":1,\"meter_id\":\"52632878\",\"received_at\":\"1969-12-31T23:59:59.000Z\"}"  # epoch -1 is an error
  rx wmbus/clock/rx  "{${base},\"boot_id\":\"0000BEEF\",\"seq\":2,\"meter_id\":\"52632878\",\"received_at\":\"2026-10-02T24:00:00.000Z\"}"
  rx wmbus/clock/rx  "{${base},\"boot_id\":\"0000BEEF\",\"seq\":3,\"meter_id\":\"52632878\",\"received_at\":\"2026-10-02T10:00:00.123Z\\n\"}"
  rx wmbus/clock/rx  "{${base},\"boot_id\":\"0000BEEF\",\"seq\":4,\"meter_id\":\"52632878\",\"received_at\":\"garbage\"}"  # field dropped, frame kept
  rx wmbus/clock/rx  "{${base},\"boot_id\":\"0000BEEF\",\"seq\":5,\"meter_id\":\"52632878\",\"received_at\":false}"
  rx wmbus/clock/rx  "{${base},\"boot_id\":\"0000BEEF\",\"seq\":6,\"meter_id\":\"52632878\",\"received_at\":null}"
  rx wmbus/odd/rx    "{${base},\"boot_id\":\"0000BEEF\",\"seq\":1,\"meter_id\":\"52632878\",\"source\":\"firmware\",\"x\":\"ą\\u0001\\u007f\\/é\",\"n\":[1.50,-0.0,1E-7,12345678901234567890],\"seq\":2}"  # dup key, own source
  rx wmbus/odd/rx    "{${base},\"boot_id\":\"0000BEEF\",\"seq\":3,\"meter_id\":\"52632878\"} {${base},\"boot_id\":\"0000BEEF\",\"seq\":4,\"meter_id\":\"11111111\"}"  # two documents
  rx wmbus/odd/rx    "5 {${base},\"boot_id\":\"0000BEEF\",\"seq\":5,\"meter_id\":\"52632878\"}"   # jq skips the 5
  rx wmbus/odd/rx    "{${base},\"boot_id\":\"0000BEEF\",\"seq\":6,\"meter_id\":\"52632878\"} xx"  # parse error after a value
  rx wmbus/odd/rx    "{${base},\"boot_id\":\"0000BEEF\\n\",\"seq\":7,\"meter_id\":\"52632878\"}"  # \n accepted by test(), cuts the fields
  rx wmbus/odd/rx    "{${base},\"boot_id\":\"0000BEEF\",\"seq\":8,\"meter_id\":\"52632878\",\"rssi_dbm\":-125.0}"
  rx wmbus/bad/rx    "{${base},\"boot_id\":\"0000BEEF\",\"seq\":0,\"meter_id\":\"52632878\"}"
  rx wmbus/bad/rx    "{${base},\"boot_id\":\"0000BEEF\",\"seq\":1.5,\"meter_id\":\"52632878\"}"
  rx wmbus/bad/rx    "{${base},\"boot_id\":\"0000BEEF\",\"seq\":\"1\",\"meter_id\":\"52632878\"}"
  rx wmbus/bad/rx    "{${base},\"boot_id\":\"0000BEE\",\"seq\":1,\"meter_id\":\"52632878\"}"
  rx wmbus/bad/rx    "{${base},\"boot_id\":\"0000BEEF\",\"seq\":1,\"meter_id\":\"52632878\",\"mode\":\"X1\"}"
  rx wmbus/bad/rx    "{${base},\"boot_id\":\"0000BEEF\",\"seq\":1,\"meter_id\":\"52632878\",\"rssi_dbm\":-126}"
  rx wmbus/bad/rx    "{${base},\"boot_id\":\"0000BEEF\",\"seq\":1,\"meter_id\":\"52632878\",\"schema\":2}"
  rx wmbus/bad/rx    '[1,2]'
  rx wmbus/bad/rx    'not json'
  rx wmbus/bad/rx    '{"schema":1,"raw":"tab	inside"}'
  rx 'wmbus//rx'     "{${base},\"boot_id\":\"0000BEEF\",\"seq\":1,\"meter_id\":\"52632878\"}"   # no board name
  rx wmbus/a/b/rx    "{${base},\"boot_id\":\"0000BEEF\",\"seq\":1,\"meter_id\":\"52632878\"}"
  rx other/rx        "{${base},\"boot_id\":\"0000BEEF\",\"seq\":1,\"meter_id\":\"52632878\"}"
  rx wmbus/empty/rx  ''
} > "${CORPUS}"
compare "corpus" "${CORPUS}"

# ── 2. generated messages ───────────────────────────────────────────────────
python3 - "${TMP}/generated" <<'PY'
import random, sys
rnd = random.Random(20261002)
pick = rnd.choice
# Each field: one of its valid forms, or (8%) one of its invalid ones.
def field(valid, invalid):
    return pick(invalid) if rnd.random() < 0.08 else pick(valid)
# No two keys that awk would compare as equal numbers (1000 and 1E3,
# 00001000 and 0001E003): that is the one deliberate difference, pinned in
# tests/test_bridge_ledger.py. Boot ids may: they are compared as strings.
boards = ["lilygo", "heltec", "xiao-seed", "1E3"]
with open(sys.argv[1], "w") as out:
    for _ in range(200):
        fields = [
            '"schema":' + field(["1", "1.0"], ["2", '"1"']),
            '"boot_id":' + field(['"A84F12C7"', '"a84f12c7"', '"651E6871"', '"999E9999"',
                                  '"0001E003"', '"00001000"'], ['"XYZ"', "1"]),
            '"seq":' + field(["1", "2", "3", "5", "4", "4", "10", "7.0", "1e3"],
                             ["0", "-1", "1.5", '"3"', "null"]),
            '"rx_task_wakeup_us":' + field(["0", "123456", "1E+3"], ["-1"]),
            '"meter_id":' + field(['"52632878"', '"77665544"', '"abcdef12"', '"00001000"'],
                                  ['"5263287"', "52632878"]),
            '"mode":' + field(['"T1"', '"C1"', '"S1"'], ['"t1"', '"X1"', "1"]),
            '"frame_crc32":' + field(['"7f56a83c"', '"7F56A83C"'], ['"7F56A83"']),
            '"frame_length":' + field(["123", "1", "12.0"], ["0", "1.5", '"123"']),
        ]
        r = field([None, "-54", "-125", "-1", "-54.5", "null"], ["-126", "0", '"-54"'])
        if r is not None:
            fields.append('"rssi_dbm":' + r)
        c = pick([None, '"2026-10-02T10:00:00.123Z"', '"2026-02-29T00:00:00.000Z"',
                  '"2026-10-02T23:59:60.999Z"', '"2026-10-02T10:00:00Z"',
                  '"2026-13-02T10:00:00.000Z"', "123", "null", '"x"'])
        if c is not None:
            fields.append('"received_at":' + c)
        rnd.shuffle(fields)
        out.write("wmbus/%s/rx\t{%s}\n" % (pick(boards), ",".join(fields)))
PY
compare "generated" "${TMP}/generated"
booked="$(wc -l < "${TMP}/py/history" | tr -d ' ')"
(( booked >= 50 )) || fail "generated: only ${booked} of 200 messages valid - the generator tests too little"

# ── 3. restart after python3 dies ───────────────────────────────────────────
QUEUE="${TMP}/queue"
mkdir -p "${QUEUE}"
MESSAGES=40
for (( i = 1; i <= MESSAGES; i++ )); do
  printf 'wmbus/lilygo/rx\t{%s,"boot_id":"A84F12C7","seq":%d,"meter_id":"52632878"}\n' "${base}" "${i}"
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
# Like the real /rx subscription (no -W), stay connected once the queue is empty.
sleep 60
STUB
chmod +x "${TMP}/broker-stub"
export STUB_QUEUE="${QUEUE}"

LIVE="${TMP}/live"
mkdir -p "${LIVE}"
STATUS_ESP_RX_RECEPTION_FILE="${LIVE}/reception"
STATUS_ESP_RX_MODE_FILE="${LIVE}/mode"
ESP_RF_RX_HISTORY_FILE="${LIVE}/history"
STATUS_ESP_RX_SEQUENCE_FILE="${LIVE}/sequence"
STATUS_ESP_RX_BOOTS_FILE="${LIVE}/boots"
STATUS_ESP_RX_CLOCK_FILE="${LIVE}/clock"
: > "${ESP_RF_RX_HISTORY_FILE}"
STDBUF_BIN="${TMP}/broker-stub"
SUB_ARGS=()
SUB_EXTRA=()
_sub_reconnect_sleep() { sleep 0.2; }

booked() { wc -l < "${ESP_RF_RX_HISTORY_FILE}" | tr -d ' '; }
booked_at_least() { (( $(booked) >= $1 )); }
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
( trap '' PIPE; _esp_rx_subscriber ) 2>"${TMP}/subscriber.err" &
SUB_PID=$!

wait_for 15 booked_at_least 10 || fail "restart: python3 never booked the first messages"
# SIGTERM, what stopping the add-on sends: the collected writes are made
# before python3 exits.
pkill -TERM -f "${BRIDGE_LEDGER} rx --reception-file ${LIVE}/reception" \
  || fail "restart: no bridge_ledger.py rx process to kill"
killed_after="$(booked)"
wait_for 30 queue_sent \
  || fail "restart: the loop did not reconnect after python3 died (stopped at message $(cat "${QUEUE}/next"))"
wait_for 10 booked_at_least $(( MESSAGES - 1 )) || true

seq_at_end() { [[ "$(awk -F '\t' '$1=="lilygo" {print $3}' "${STATUS_ESP_RX_SEQUENCE_FILE}")" == "${MESSAGES}" ]]; }
# Nothing arrives after the last message: its rows are written once due.
wait_for 10 seq_at_end || true
final="$(booked)"
tail -n 1 "${ESP_RF_RX_HISTORY_FILE}" | jq -e ".seq == ${MESSAGES}" >/dev/null \
  || fail "restart: the last message was not booked - python3 was not started again"
(( final > killed_after )) || fail "restart: nothing booked after python3 was killed"
(( final >= MESSAGES - 1 )) \
  || fail "restart: ${final} of ${MESSAGES} messages booked; more than the one in flight was lost"
[[ "$(awk -F '\t' '$1=="lilygo" {print $3}' "${STATUS_ESP_RX_SEQUENCE_FILE}")" == "${MESSAGES}" ]] \
  || fail "restart: sequence file does not end at ${MESSAGES}"
leftovers="$(find "${LIVE}" -name '*.tmp.*')"
[[ -z "${leftovers}" ]] || fail "restart: temporary files left behind: ${leftovers}"

# ── 4. python3 killed hard (SIGKILL) mid-stream ─────────────────────────────
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
sent_at_least() { local n; n="$(cat "${QUEUE}/next")"; [[ "${n}" =~ ^[0-9]+$ ]] && (( n >= $1 )); }
pkill -KILL -P "${SUB_PID}" 2>/dev/null || true
kill -KILL "${SUB_PID}" 2>/dev/null || true
wait "${SUB_PID}" 2>/dev/null || true
pkill -KILL -f "${BRIDGE_LEDGER} rx --reception-file ${LIVE}/reception" 2>/dev/null || true
for (( i = MESSAGES + 1; i <= 2 * MESSAGES; i++ )); do
  printf 'wmbus/lilygo/rx\t{%s,"boot_id":"A84F12C7","seq":%d,"meter_id":"52632878"}\n' "${base}" "${i}"
done >> "${QUEUE}/messages"
MESSAGES=$(( 2 * MESSAGES ))
( trap '' PIPE; _esp_rx_subscriber ) 2>>"${TMP}/subscriber.err" &
SUB_PID=$!
wait_for 15 sent_at_least $(( MESSAGES - 20 )) || fail "SIGKILL: the subscriber did not start again"
pkill -KILL -f "${BRIDGE_LEDGER} rx --reception-file ${LIVE}/reception" \
  || fail "SIGKILL: no bridge_ledger.py rx process to kill"
wait_for 30 queue_sent || fail "SIGKILL: the loop did not reconnect after python3 was killed"
wait_for 10 seq_at_end || fail "SIGKILL: the restarted process did not book the last message"
check_tsv "${STATUS_ESP_RX_RECEPTION_FILE}" 6
check_tsv "${STATUS_ESP_RX_MODE_FILE}" 4
check_tsv "${STATUS_ESP_RX_SEQUENCE_FILE}" 6
check_tsv "${STATUS_ESP_RX_BOOTS_FILE}" 5
check_tsv "${STATUS_ESP_RX_CLOCK_FILE}" 6
check_jsonl "${ESP_RF_RX_HISTORY_FILE}"
leftovers="$(find "${LIVE}" -name '*.tmp.*')"
[[ -z "${leftovers}" ]] || fail "SIGKILL: temporary files left behind: ${leftovers}"

echo "PASS: /rx via bridge_ledger.py matches the recorded bash output (corpus + 200 generated, ${booked} valid) and survives python3 stopped (${final}/40 booked) and killed (files whole)"
