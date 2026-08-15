#!/usr/bin/env bash
# Regression test: the upstream issue report must be buildable for a CONFIGURED
# meter, not only for a candidate.
#
# A candidate has a keyed row in status_candidate_raw.tsv. A meter that was
# added a while ago has none — it aged out of the candidate tables — so the
# report has to fall back to the rolling all-frames buffer and match the frame
# by the meter id in little-endian order. Before that fallback the button
# simply reported "no raw telegram" for every configured meter, which is also
# why there was no way to look at a configured meter's raw frame at all.
#
# The decoder is stubbed: this test is about where the report's parts come
# from, not about wmbusmeters' analysis, and CI runs it without the image.
set -euo pipefail

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$(( PASS + 1 )); }
fail() { echo "FAIL: $*" >&2; FAIL=$(( FAIL + 1 )); }

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
[[ "${SCRIPT_DIR}" == "${SCRIPT_PATH}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

command -v python3 >/dev/null 2>&1 || {
  echo "FAIL: missing python3" >&2
  exit 1
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# A real hydrodigit frame from the decode fixtures: id 03264950 appears inside
# it as 50492603 (little-endian), which is exactly what the fallback matches on.
RAW="$(tr -d '[:space:]' < "${ROOT_DIR}/tests/fixtures/hydrodigit/03264950.hex")"
MID="03264950"
KEY="00112233445566778899AABBCCDDEEFF"

printf '%s\t%s\t%s\n' "2026-08-15T06:00:00Z" "${#RAW}" "${RAW}" \
  > "${WORK_DIR}/status_recent_raw.tsv"
# Deliberately absent: status_candidate_raw.tsv and status_candidates.tsv.
cat > "${WORK_DIR}/options.json" <<JSON
{"meters": [{"id": "Cold_Water", "meter_id": "${MID}", "type": "hydrodigit", "key": "${KEY}"}]}
JSON
printf '%s\t%s\t%s\n' "${MID}" "2026-08-15T06:00:01Z" '{"media":"water","meter":"hydrodigit","total_m3":0.066}' \
  > "${WORK_DIR}/status_meter_last_json.tsv"

# Stub decoder: prints an --analyze-shaped block on stdout and records the
# arguments it received to a side file. The arguments must NOT go to stdout —
# the report embeds the decoder's output verbatim, so a stub that echoed its
# own command line would put the AES key in the report and make the leak check
# below fail against a decoder that is in fact clean (verified separately:
# `wmbusmeters --analyze=<key>` on an encrypted frame prints 96 lines and not
# one occurrence of the key).
STUB="${WORK_DIR}/wmbusmeters"
ARGV_FILE="${WORK_DIR}/argv.txt"
cat > "${STUB}" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" > "${ARGV_FILE}"
echo "Auto driver    : hydrodigit"
echo "002   : b409 dll-mfct (BMT)"
echo "004   : 50492603 dll-id (03264950)"
echo "017 C!: 66000000 (\\"total_m3\\":0.066)"
STUB
chmod +x "${STUB}"

REPORT_OUT="${WORK_DIR}/report.txt"
WMBUS_BASE="${WORK_DIR}" python3 - "${ROOT_DIR}" "${STUB}" "${MID}" "${REPORT_OUT}" <<'PY'
import json
import sys

root, stub, mid, out = sys.argv[1:5]
sys.path.insert(0, f"{root}/rootfs/usr/bin")
import webui

webui.WMBUSMETERS_BIN = stub
ok, payload = webui.candidate_issue_report(mid)
missing_ok, missing_payload = webui.candidate_issue_report("11223344")
with open(out, "w", encoding="utf-8") as fh:
    json.dump({
        "ok": ok,
        "report": payload.get("report", ""),
        "key_used": payload.get("key_used"),
        "raw_ts": payload.get("raw_ts", ""),
        "missing_ok": missing_ok,
        "missing_error": missing_payload.get("error", ""),
    }, fh)
PY

field() { python3 -c "import json,sys;print(json.load(open(sys.argv[1],encoding='utf-8')).get(sys.argv[2]))" "${REPORT_OUT}" "$1"; }

REPORT="$(field report)"

[[ "$(field ok)" == "True" ]] \
  && pass "configured meter: report built without a candidate row" \
  || fail "configured meter: report not built"

grep -qi -- "${RAW}" <<<"${REPORT}" \
  && pass "raw frame resolved from the rolling buffer" \
  || fail "raw frame missing from the report"

grep -q "suggested driver: hydrodigit" <<<"${REPORT}" \
  && pass "driver taken from the meter's configuration" \
  || fail "driver line: $(grep 'suggested driver' <<<"${REPORT}" || echo missing)"

grep -q "type/medium: water" <<<"${REPORT}" \
  && pass "medium taken from the last decoded telegram" \
  || fail "medium line: $(grep 'type/medium' <<<"${REPORT}" || echo missing)"

grep -q "manufacturer: BMT" <<<"${REPORT}" \
  && pass "manufacturer read back out of the analysis" \
  || fail "manufacturer line: $(grep 'manufacturer' <<<"${REPORT}" || echo missing)"

# The single most important property of this report: it is meant to be pasted
# into a public issue.
if grep -qi -- "${KEY}" <<<"${REPORT}"; then
  fail "AES key leaked into the report"
else
  pass "AES key never appears in the report"
fi

[[ "$(field key_used)" == "True" ]] \
  && pass "configured key was used for the analysis" \
  || fail "key_used=$(field key_used) (expected True)"

grep -q -- "--analyze=${KEY}" "${ARGV_FILE}" \
  && pass "decoder was invoked with --analyze=<key>" \
  || fail "decoder arguments: $(cat "${ARGV_FILE}" 2>/dev/null || echo "not invoked")"

[[ "$(field raw_ts)" == "2026-08-15T06:00:00Z" ]] \
  && pass "timestamp comes from the matched frame" \
  || fail "raw_ts=$(field raw_ts)"

[[ "$(field missing_ok)" == "False" && "$(field missing_error)" == "no_raw_telegram" ]] \
  && pass "id nobody ever heard: no_raw_telegram" \
  || fail "unknown id: ok=$(field missing_ok) error=$(field missing_error)"

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
