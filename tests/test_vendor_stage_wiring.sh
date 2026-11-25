#!/usr/bin/env bash
# shellcheck disable=SC2034  # VENDOR_* are read by the sourced 15-external.sh
# The vendor stage's JSON must leave _main_wmbusmeters_stage on its stdout,
# next to the wmbusmeters lines - not go into wmbusmeters' stdin.
#
# dev.529 wired it as `tee >(stage) | wmbusmeters`: a process substitution
# inherits the stdout of the command it is expanded for (tee's, the pipe into
# wmbusmeters), so every decoded Hydroclima line was fed back to wmbusmeters as
# input and dropped as not hex. The unit tests ran the stage alone and passed.
#
# Here the real function runs with the real vendor_formats.py stage and a
# stand-in for wmbusmeters that tags what it reads: the stage's JSON must come
# out once, untagged, and the stand-in must see only the RAW lines.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# shellcheck source=../rootfs/usr/bin/bridge-lib/15-external.sh
source rootfs/usr/bin/bridge-lib/15-external.sh

# The stand-in for the main wmbusmeters: every line it reads, tagged.
_main_wmbusmeters_core() { while IFS= read -r l; do printf 'WMB<%s>\n' "${l}"; done; }

VENDOR_TOOL="${ROOT_DIR}/rootfs/usr/bin/vendor_formats.py"
VENDOR_FORMATS_DIR="${ROOT_DIR}/rootfs/usr/share/wmbus-bridge/formats"
VENDOR_METER_DIR="${TMP}/meters"
STATUS_VENDOR_FORMATS_FILE=""
VENDOR_METERS_COUNT=1
mkdir -p "${VENDOR_METER_DIR}"
printf 'name=radiator\nid=78240400\ndriver=vendor_bmeters_hydroclima_v34\n' > "${VENDOR_METER_DIR}/meter-0001"

LONG="2D44B009000424783408780F79130000E6F8DD118368CF6A1A6DE36B376E086C2C6E2C6E596B596B596B546B5933"
OTHER="1944304C72242421D401A2013D4013DD8B46A4999C1293E582CC"
printf '%s\n%s\n' "${LONG}" "${OTHER}" | _main_wmbusmeters_stage > "${TMP}/out"

fail=0
json="$(grep -c '^{"_":"telegram".*"id":"78240400".*"allocation_hca":51.7' "${TMP}/out" || true)"
if [[ "${json}" != "1" ]]; then
  echo "FAIL: expected the vendor JSON once on stdout, got ${json}"; fail=1
fi
if grep -q '^WMB<{' "${TMP}/out"; then
  echo "FAIL: vendor JSON went into wmbusmeters' stdin"; fail=1
fi
for raw in "${LONG}" "${OTHER}"; do
  grep -qx "WMB<${raw}>" "${TMP}/out" || { echo "FAIL: wmbusmeters did not get ${raw:0:16}..."; fail=1; }
done

# Without a vendor meter the stage is not involved at all.
VENDOR_METERS_COUNT=0
printf '%s\n' "${LONG}" | _main_wmbusmeters_stage > "${TMP}/out0"
if [[ "$(cat "${TMP}/out0")" != "WMB<${LONG}>" ]]; then
  echo "FAIL: with no vendor meter the output must be wmbusmeters' alone"; fail=1
fi

if (( fail )); then
  echo "--- output:"; cat "${TMP}/out"
  exit 1
fi
echo "PASS: vendor stage output joins the decode stream, wmbusmeters gets RAW only"
