#!/usr/bin/env bash
# Decode smoke-test: pipe golden HEX fixtures through `wmbusmeters stdin:hex`
# and compare the normalized JSON against committed golden files. Guards
# WMBUSMETERS_COMMIT bumps in the Dockerfile: a bump that renames fields or
# breaks decoding of a known telegram fails this test before the image ships.
#
# Manifest: tests/fixtures/golden.tsv, one fixture per line:
#   <dir>/<id> <TAB> <driver> <TAB> <key>
# where <dir>/<id>.hex is the raw telegram and <key> is one of:
#   NOKEY          — unencrypted telegram
#   32 hex chars   — literal AES key; ONLY for keys that are already
#                    public (e.g. upstream wmbusmeters driver test keys)
#   anything else  — name of an environment variable holding the key
#                    (for private keys, e.g. GitHub Actions secrets;
#                    never store private keys in git)
#
# Golden files: tests/fixtures/<dir>/<id>.golden.json (jq -S normalized,
# volatile `timestamp` removed). When a golden file is missing the decoded
# JSON is printed so it can be reviewed and committed (bootstrap). Set
# GOLDEN_REQUIRE=1 (CI default once goldens exist) to fail on missing files.
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
[[ "${SCRIPT_DIR}" == "${SCRIPT_PATH}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd)"
FIXTURE_DIR="${SCRIPT_DIR}/fixtures"
MANIFEST="${FIXTURE_DIR}/golden.tsv"

if ! command -v wmbusmeters >/dev/null 2>&1; then
  echo "SKIP: missing wmbusmeters"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: missing jq"
  exit 0
fi

if [[ ! -f "${MANIFEST}" ]]; then
  echo "FAIL: missing manifest ${MANIFEST}" >&2
  exit 1
fi

PASS=0
FAIL=0
BOOTSTRAP=0

pass() { echo "PASS: $*"; PASS=$(( PASS + 1 )); }
fail() { echo "FAIL: $*" >&2; FAIL=$(( FAIL + 1 )); }

while IFS=$'\t' read -r fixture driver key_env; do
  fixture="${fixture%$'\r'}"
  driver="${driver%$'\r'}"
  key_env="${key_env%$'\r'}"
  [[ -n "${fixture}" ]] || continue
  [[ "${fixture}" == \#* ]] && continue

  meter_id="${fixture##*/}"
  hex_file="${FIXTURE_DIR}/${fixture}.hex"
  golden_file="${FIXTURE_DIR}/${fixture}.golden.json"

  if [[ ! -f "${hex_file}" ]]; then
    fail "${fixture}: missing fixture ${hex_file}"
    continue
  fi

  key="NOKEY"
  if [[ "${key_env}" =~ ^[0-9A-Fa-f]{32}$ ]]; then
    key="${key_env}"
  elif [[ "${key_env}" != "NOKEY" ]]; then
    key="${!key_env:-}"
    if [[ -z "${key}" ]]; then
      fail "${fixture}: key env ${key_env} is empty or unset"
      continue
    fi
  fi

  # Meter id matching in wmbusmeters is case-sensitive against the
  # lowercase hex id from the telegram — pass the id lowercased.
  meter_id_lc="$(echo "${meter_id}" | tr '[:upper:]' '[:lower:]')"

  hex="$(tr -d '\r\n[:space:]' < "${hex_file}")"
  decoded_json="$(
    printf '%s\n' "${hex}" \
      | wmbusmeters --silent --format=json stdin:hex \
          "golden_${meter_id_lc}" "${driver}" "${meter_id_lc}" "${key}" \
      | jq -c 'select(type=="object")' \
      | head -n 1
  )"

  if [[ -z "${decoded_json}" ]]; then
    fail "${fixture}: wmbusmeters produced no JSON (driver=${driver})"
    continue
  fi

  # Normalize: drop decode-time timestamp (volatile), drop the synthetic
  # meter name, sort keys. device_date_time comes from the telegram itself
  # and stays. The id stays and must match the fixture id.
  normalized="$(jq -S 'del(.timestamp) | del(.name)' <<<"${decoded_json}")"

  if [[ ! -f "${golden_file}" ]]; then
    if [[ "${GOLDEN_REQUIRE:-0}" == "1" ]]; then
      fail "${fixture}: missing golden file ${golden_file}"
    else
      BOOTSTRAP=$(( BOOTSTRAP + 1 ))
      echo "BOOTSTRAP: ${fixture}: no golden file yet — decoded output below:"
      echo "----- ${fixture}.golden.json (proposed) -----"
      echo "${normalized}"
      echo "----- end -----"
    fi
    continue
  fi

  golden="$(jq -S 'del(.timestamp) | del(.name)' < "${golden_file}")"
  if [[ "${normalized}" == "${golden}" ]]; then
    pass "${fixture} (driver=${driver})"
  else
    fail "${fixture}: decoded JSON differs from golden"
    diff <(echo "${golden}") <(echo "${normalized}") | sed 's/^/  /' >&2 || true
  fi
done < "${MANIFEST}"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed, ${BOOTSTRAP} bootstrap"
[[ "${FAIL}" -eq 0 ]]
