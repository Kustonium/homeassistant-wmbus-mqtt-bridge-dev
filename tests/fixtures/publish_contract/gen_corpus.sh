#!/usr/bin/env bash
# Regenerates the inputs of tests/test_publish_contract.sh from a wmbusmeters
# binary built at the commit pinned in the Dockerfile (WMBUSMETERS_COMMIT):
#
#   decoded.jsonl      one decoded telegram per golden fixture, exactly as
#                      `wmbusmeters --format=json` prints it (field order kept),
#                      with the volatile timestamp fixed;
#   listfields/<d>.txt `wmbusmeters --listfields=<d>` for every driver in
#                      decoded.jsonl and extra.jsonl, so the test sees the same
#                      field descriptions as the add-on without the binary.
#
# extra.jsonl is written by hand (drivers or field shapes without a golden
# telegram) and is not touched here.
#
# Usage: WMBUSMETERS=/path/to/wmbusmeters tests/fixtures/publish_contract/gen_corpus.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="$(cd "${HERE}/.." && pwd)"
WMB="${WMBUSMETERS:-wmbusmeters}"
TS="2026-10-06T08:00:00Z"

command -v "${WMB}" >/dev/null 2>&1 || { echo "missing wmbusmeters (set WMBUSMETERS)" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "missing jq" >&2; exit 1; }

out="${HERE}/decoded.jsonl"
: > "${out}"
while IFS=$'\t' read -r fixture driver key; do
  fixture="${fixture%$'\r'}"; driver="${driver%$'\r'}"; key="${key%$'\r'}"
  [[ -n "${fixture}" && "${fixture}" != \#* ]] || continue
  # Private keys live in CI secrets only; such fixtures cannot be regenerated here.
  [[ "${key}" == "NOKEY" || "${key}" =~ ^[0-9A-Fa-f]{32}$ ]] || { echo "skip ${fixture}: key from env" >&2; continue; }
  id="${fixture##*/}"
  hex="$(tr -d '\r\n[:space:]' < "${FIXTURES}/${fixture}.hex")"
  # The meter name becomes the Home Assistant device name; keep it readable.
  line="$(printf '%s\n' "${hex}" \
    | "${WMB}" --silent --format=json stdin:hex "Meter_${id}" "${driver}" "${id,,}" "${key}" \
    | grep -m1 '^{' || true)"
  [[ -n "${line}" ]] || { echo "no JSON for ${fixture}" >&2; exit 1; }
  # Replace the value of "timestamp" in place, so the rest stays the decoder's
  # text byte for byte - that text is what the add-on publishes as state.
  line="$(sed -E "s/\"timestamp\":\"[^\"]*\"/\"timestamp\":\"${TS}\"/" <<<"${line}")"
  printf '%s\n' "${line}" >> "${out}"
done < "${FIXTURES}/golden.tsv"

mkdir -p "${HERE}/listfields"
rm -f "${HERE}/listfields/"*.txt
cat "${out}" "${HERE}/extra.jsonl" | jq -r '.meter // empty' | sort -u | while read -r d; do
  "${WMB}" "--listfields=${d}" > "${HERE}/listfields/${d}.txt" 2>/dev/null || true
  # An unknown driver (hand-written extra.jsonl) prints nothing useful; keep
  # an empty file so the test does not mistake it for a missing fixture.
done
echo "wrote $(wc -l < "${out}") telegrams, $(ls "${HERE}/listfields" | wc -l) driver catalogs"
