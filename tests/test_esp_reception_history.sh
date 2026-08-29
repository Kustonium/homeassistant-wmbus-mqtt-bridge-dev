#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=rootfs/usr/bin/bridge-lib/03-tsv.sh
source "${ROOT}/rootfs/usr/bin/bridge-lib/03-tsv.sh"

command -v jq >/dev/null 2>&1 || { echo "FAIL: missing jq" >&2; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "FAIL: missing flock" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
SUMMARY="${TMP}/reception.tsv"
HISTORY="${TMP}/history.jsonl"
RF_HISTORY="${TMP}/rf_history.jsonl"
SEQUENCE="${TMP}/sequence.tsv"
touch "${SUMMARY}" "${HISTORY}" "${RF_HISTORY}" "${SEQUENCE}"

_upsert_esp_meter_reception "${SUMMARY}" 00089907 lr1121 100 wmbus/lr1121/telegram
_upsert_esp_meter_reception "${SUMMARY}" 00089907 heltec 101 wmbus/heltec/telegram
_upsert_esp_meter_reception "${SUMMARY}" 00089907 lr1121 105 wmbus/lr1121/telegram

[[ "$(awk -F '\t' '$1=="00089907" && $2=="lr1121" {print $3 FS $4 FS $5}' "${SUMMARY}")" == $'100\t105\t2' ]] \
  || { echo "FAIL: LR1121 first/last/count" >&2; exit 1; }
[[ "$(awk -F '\t' '$1=="00089907" && $2=="heltec" {print $3 FS $4 FS $5}' "${SUMMARY}")" == $'101\t101\t1' ]] \
  || { echo "FAIL: Heltec independent row" >&2; exit 1; }

for n in 1 2 3 4 5; do
  _append_esp_rx_history "${HISTORY}" "${n}" lr1121 00089907 wmbus/lr1121/telegram
done
_trim_esp_rx_history "${HISTORY}" 4 3

[[ "$(wc -l < "${HISTORY}" | tr -d ' ')" == "3" ]] \
  || { echo "FAIL: history retention" >&2; exit 1; }
jq -e -s 'length == 3 and .[0].time == 3 and .[2].time == 5 and all(.[]; .meter_id == "00089907")' \
  "${HISTORY}" >/dev/null \
  || { echo "FAIL: history JSONL content" >&2; exit 1; }

RX_PAYLOAD='{"schema":1,"boot_id":"A84F12C7","seq":7,"rx_task_wakeup_us":123456,"meter_id":"00089907","mode":"T1","rssi_dbm":-54,"frame_crc32":"7F56A83C","frame_length":123}'
RX_NORMALIZED="$(_normalize_esp_rx_payload <<< "${RX_PAYLOAD}")"
[[ "$(jq -r '.meter_id + " " + .boot_id + " " + .frame_crc32' <<< "${RX_NORMALIZED}")" == "00089907 A84F12C7 7F56A83C" ]] \
  || { echo "FAIL: structured RF RX normalization" >&2; exit 1; }
[[ -z "$(_normalize_esp_rx_payload <<< '{"schema":1,"meter_id":"NOT_AN_ID"}')" ]] \
  || { echo "FAIL: malformed RF RX payload accepted" >&2; exit 1; }

_append_esp_rf_rx_history "${RF_HISTORY}" 200 lr1121 "${RX_NORMALIZED}"
jq -e -s 'length == 1 and .[0].source == "lr1121" and .[0].bridge_rx_time == 200 and .[0].seq == 7' \
  "${RF_HISTORY}" >/dev/null \
  || { echo "FAIL: structured RF RX history" >&2; exit 1; }

_upsert_esp_rx_sequence "${SEQUENCE}" lr1121 A84F12C7 7 200
_upsert_esp_rx_sequence "${SEQUENCE}" lr1121 A84F12C7 10 201
_upsert_esp_rx_sequence "${SEQUENCE}" lr1121 A84F12C7 10 202
[[ "$(awk -F '\t' '$1=="lr1121" {print $3 FS $4 FS $5}' "${SEQUENCE}")" == $'10\t2\t1' ]] \
  || { echo "FAIL: RX sequence gap accounting" >&2; exit 1; }
_upsert_esp_rx_sequence "${SEQUENCE}" lr1121 DEADBEEF 1 203
[[ "$(awk -F '\t' '$1=="lr1121" {print $2 FS $3 FS $4 FS $5}' "${SEQUENCE}")" == $'DEADBEEF\t1\t0\t0' ]] \
  || { echo "FAIL: RX sequence boot reset" >&2; exit 1; }

# A late or duplicated delivery must not invent a gap.
#
# The tracker used to store the LAST sequence number it saw, so an arrival
# below the current maximum moved the baseline backwards and the next
# in-order frame then looked like a jump. One redelivery therefore produced
# a phantom 'missing' - observed on hardware 2026-08-21, when three boards
# reported missing=1 in the same second while the broker was simply
# redelivering. Feed 1,2,3,5,4,6,7: exactly one frame (4) was genuinely
# late, so missing must stay at 1 and never grow as later frames arrive.
BOOTS="${TMP}/boots.tsv"
SEQ2="${TMP}/sequence_reorder.tsv"
touch "${SEQ2}" "${BOOTS}"

for n in 1 2 3 5 4 6 7; do
  _upsert_esp_rx_sequence "${SEQ2}" lilygo AAAA "${n}" 1000
done

[[ "$(awk -F '\t' '$1=="lilygo" {print $3 FS $4 FS $5}' "${SEQ2}")" == $'7\t1\t1' ]] \
  || { echo "FAIL: reordered delivery must not invent gaps" >&2; exit 1; }

# One row per boot, so a restart leaves a trace. Without this the sequence
# reset erases the evidence of the very event you are trying to see.
_upsert_esp_rx_boot "${BOOTS}" lilygo AAAA 1000
_upsert_esp_rx_boot "${BOOTS}" lilygo AAAA 1100
_upsert_esp_rx_boot "${BOOTS}" lilygo BBBB 2000

[[ "$(awk -F '\t' '$2=="AAAA" {print $3 FS $4 FS $5}' "${BOOTS}")" == $'1000\t1100\t2' ]] \
  || { echo "FAIL: boot row must accumulate first/last/events" >&2; exit 1; }
[[ "$(wc -l < "${BOOTS}")" -eq 2 ]] \
  || { echo "FAIL: a new boot_id must add a row, not overwrite" >&2; exit 1; }

# BusyBox awk treats digit-E-digit values as numeric strings. Large exponents
# overflow, so a plain `$2 == boot_id` can consider distinct boot IDs equal.
# XIAO produced 651E6871 in the field, exposing this on real hardware.
SCI_BOOTS="${TMP}/boots_scientific.tsv"
SCI_SEQUENCE="${TMP}/sequence_scientific.tsv"
touch "${SCI_BOOTS}" "${SCI_SEQUENCE}"

_upsert_esp_rx_boot "${SCI_BOOTS}" xiaoseed 999E9999 1000
for n in 1 2 3 4 5; do
  _upsert_esp_rx_boot "${SCI_BOOTS}" xiaoseed 651E6871 "$((1000 + n))"
done

[[ "$(awk -F '\t' '"boot:" $2=="boot:651E6871" {print $3 FS $4 FS $5}' "${SCI_BOOTS}")" == $'1001\t1005\t5' ]] \
  || { echo "FAIL: scientific-looking boot_id must accumulate its own row" >&2; exit 1; }
[[ "$(wc -l < "${SCI_BOOTS}")" -eq 2 ]] \
  || { echo "FAIL: distinct scientific-looking boot_ids must not collide" >&2; exit 1; }

_upsert_esp_rx_sequence "${SCI_SEQUENCE}" xiaoseed 999E9999 40 1000
_upsert_esp_rx_sequence "${SCI_SEQUENCE}" xiaoseed 651E6871 1 1001
[[ "$(awk -F '\t' '$1=="xiaoseed" {print $2 FS $3 FS $4 FS $5}' "${SCI_SEQUENCE}")" == $'651E6871\t1\t0\t0' ]] \
  || { echo "FAIL: scientific-looking boot_id must reset sequence accounting" >&2; exit 1; }

echo "PASS: ESP reception summary and bounded history"
