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

echo "PASS: ESP reception summary and bounded history"
