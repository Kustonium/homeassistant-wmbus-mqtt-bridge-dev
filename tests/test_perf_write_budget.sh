#!/usr/bin/env bash
# Performance regression test: bytes written per message.
#
# Every message from every ESP changes a row of a table holding a row per
# meter and board (status_esp_rx_reception.tsv, status_esp_meter_reception.tsv,
# ...). Writing such a table means writing all of it again to a temporary file
# that replaces it, and ext4 pushes each of those to the disk at once. Written
# per message that was ~1.1 MB/s on a 5-board site with ~210 meters on air
# (~95 GB a day), harmless on an SSD and wearing out the SD card of a
# Raspberry Pi. Nothing fails when that happens, so this test counts the bytes.
#
# Each path booked by bridge_ledger.py gets a batch of LEDGER_BATCH messages at
# the rate of that site (3 telegrams/s heard by 5 boards: 15 messages/s on each
# subscription), through one process, with the clock moved on per message, on
# tables already holding a row for every meter on air and board. The bytes are
# the process's wchar from /proc/self/io: every byte it hands to write(2),
# whatever the filesystem below (tmpfs in CI). The batch ends with the final
# write of what was collected, so it is counted too.
#
# Like the fork budget, the number that matters is per message at 10/50/200
# meters on air; the budget is absolute, at 200 meters, about 25% above what
# was measured on 2026-10-03 (the number in the comment). Raise a budget only
# together with an explanation in the commit that added the bytes.
#
# BRIDGE_LEDGER_PY points the test at another bridge_ledger.py (e.g. an older
# one, to see what it writes).
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
[[ "${SCRIPT_DIR}" == "${SCRIPT_PATH}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LEDGER="${BRIDGE_LEDGER_PY:-${ROOT_DIR}/rootfs/usr/bin/bridge_ledger.py}"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -r /proc/self/io ]] || { echo "SKIP: /proc/self/io not available"; exit 0; }
command -v python3 >/dev/null 2>&1 || fail "missing python3"

# ── budgets: bytes per message at 200 meters on air, 5 boards ───────────────
# (written per message, before the deferred writes, it was 53790 for /rx,
# 57330 for the tracker and 36573 for the RAW counter)
BUDGET_RSSI=90         #  72: status_rssi.tsv, 10 configured meters
BUDGET_RX=1200         # 954: six /rx tables and the JSONL history
BUDGET_TRACKER=1070    # 852: three tracker tables and the JSONL history
BUDGET_RAW=670         # 536: counter, ring, rate, status.json, events

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

python3 - "${LEDGER}" "${ROOT_DIR}" "${TMP}" > "${TMP}/measured" <<'PY'
import importlib.util, os, sys
ledger, root, tmp = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("bl", ledger)
bl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bl)

BOARDS, RATE, BATCH, CONFIGURED = 5, 15.0, 300, 10
QWATER = "".join(open(f"{root}/tests/fixtures/qwaterv2/52632878.hex").read().split()).upper()
clock = [1_790_935_200.0]
bl.now = lambda: clock[0]

def wchar():
    for line in open("/proc/self/io"):
        if line.startswith("wchar:"):
            return int(line.split()[1])

def frame(meter):
    return QWATER[:8] + meter[6:8] + meter[4:6] + meter[2:4] + meter[0:2] + QWATER[16:]

def feed(handler_run, book, lines):
    """Lines through the book's loop, the clock moving on at RATE per line."""
    def stream():
        for line in lines:
            yield line
            clock[0] += 1 / RATE
    handler_run(book, stream())

def measure(name, make, message, run):
    for m in (10, 50, 200):
        d = f"{tmp}/{name}-{m}"
        os.makedirs(f"{d}/meters")
        meters = [f"{10000000 + 7919 * i:08d}" for i in range(m)]
        for meter in meters[:CONFIGURED]:
            open(f"{d}/meters/meter-{meter}", "w").write(f"name=m{meter}\nid={meter}\n")
        # Warm-up: a row for every meter and board, as on a running site.
        book = make(d)
        feed(run, book, [message(meter, b, i) for i, (meter, b) in
                         enumerate((x, y) for x in meters for y in range(BOARDS))])
        book = make(d)
        lines = [message(meters[(i * 7) % m], i % BOARDS, i) for i in range(BATCH)]
        null = open(os.devnull, "w")
        out, sys.stdout = sys.stdout, null
        before = wchar()
        try:
            feed(run, book, lines)
        finally:
            after = wchar()
            sys.stdout = out
        print(f"{name}\t{m}\t{(after - before) // BATCH}")

def rx_message(meter, b, i):
    return (f'wmbus/b{b}/rx\t{{"schema":1,"boot_id":"A84F12C{b}","seq":{i + 1},"rx_task_wakeup_us":1,"meter_id":"{meter}",'
            f'"mode":"T1","rssi_dbm":-60,"frame_crc32":"7F56A83C","frame_length":74,'
            f'"received_at":"2026-10-03T10:00:00.000Z"}}\n').encode()

def touch(d, *names):
    for n in names:
        open(f"{d}/{n}", "a").close()

def make_rssi(d):
    return bl.RssiBook(f"{d}/meters", f"{d}/rssi")

def make_rx(d):
    return bl.RxBook(*(f"{d}/{n}" for n in ("reception", "mode", "history", "sequence", "boots", "clock")))

def make_tracker(d):
    touch(d, "devices", "meter_device")  # created by bridge.sh at start
    return bl.TrackerBook(1, *(f"{d}/{n}" for n in ("devices", "meter_device", "reception", "history")))

def make_raw(d):
    os.makedirs(f"{d}/preview", exist_ok=True)
    os.makedirs(f"{d}/last", exist_ok=True)
    touch(d, "candidates", "seen")
    args = bl._parser().parse_args([
        "raw", *(f"--{n}-file={d}/{n}" for n in (
            "raw-count", "last-raw", "recent-raw", "broker-error", "events", "rate",
            "rate-history", "status-json", "discovery-flag", "candidates", "seen",
            "candidate-raw", "candidate-analysis")),
        f"--meter-dir={d}/meters", f"--preview-meter-dir={d}/preview",
        f"--preview-last-dir={d}/last", f"--preview-state-file={d}/states"])
    return bl.RawBook(args, open(os.devnull, "w"))

def run_raw(book, stream):
    bl.run_lines(book, stream, sys.stderr)

def run_msg(book, stream):
    bl.run(book, stream, sys.stderr)

measure("rssi", make_rssi, lambda m, b, i: f"wmbus/b{b}/rssi/{m}\t-{55 + b}\n".encode(), run_msg)
measure("rx", make_rx, rx_message, run_msg)
measure("tracker", make_tracker, lambda m, b, i: f"wmbus/b{b}/telegram\t{frame(m)}\n".encode(), run_msg)
measure("raw", make_raw, lambda m, b, i: f"{frame(m)}\n".encode(), run_raw)
PY

declare -A R
while IFS=$'\t' read -r path m bytes; do R[${path},${m}]="${bytes}"; done < "${TMP}/measured"

declare -A BUDGET=([rssi]="${BUDGET_RSSI}" [rx]="${BUDGET_RX}" [tracker]="${BUDGET_TRACKER}" [raw]="${BUDGET_RAW}")
declare -A LABEL=(
  [rssi]="ledger rssi/<id> (10 configured)"
  [rx]="ledger /rx"
  [tracker]="ledger /telegram tracker"
  [raw]="ledger RAW counter"
)
printf '%-36s%9s%9s%9s%9s\n' "bytes written per message ->" "10" "50" "200" "budget"
failures=()
for s in rssi rx tracker raw; do
  printf '%-36s%9s%9s%9s%9s\n' "${LABEL[${s}]}" "${R[${s},10]}" "${R[${s},50]}" "${R[${s},200]}" "${BUDGET[${s}]}"
  (( R[${s},200] <= BUDGET[${s}] )) \
    || failures+=("${LABEL[${s}]}: ${R[${s},200]} bytes per message at 200 meters on air, budget ${BUDGET[${s}]}")
done
if (( ${#failures[@]} )); then
  printf 'FAIL: %s\n' "${failures[@]}" >&2
  exit 1
fi
echo "PASS: bytes written per message within budget (${LEDGER##*/}, 5 boards, 15 messages/s)"
