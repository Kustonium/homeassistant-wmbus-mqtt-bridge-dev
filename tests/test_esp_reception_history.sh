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
touch "${SUMMARY}" "${HISTORY}"

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

echo "PASS: ESP reception summary and bounded history"
