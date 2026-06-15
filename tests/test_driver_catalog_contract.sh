#!/usr/bin/env bash
# Regression test: WebUI driver catalog generation must include upstream's
# built-in C++ drivers. The CLI option was renamed upstream; both names must be
# handled so drivers such as izar do not disappear from the UI.
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
[[ "${SCRIPT_DIR}" == "${SCRIPT_PATH}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKERFILE="${ROOT_DIR}/Dockerfile"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

line_of() {
  local pattern="$1"
  grep -n -F -- "${pattern}" "${DOCKERFILE}" | head -n 1 | cut -d: -f1 || true
}

listdrivers_line="$(line_of '/out/wmbusmeters --listdrivers')"
listmeters_line="$(line_of '/out/wmbusmeters --listmeters')"

[[ -n "${listdrivers_line}" ]] || fail "Dockerfile does not try --listdrivers"
[[ -n "${listmeters_line}" ]] || fail "Dockerfile does not keep --listmeters fallback"
(( listdrivers_line < listmeters_line )) || fail "--listdrivers must be tried before --listmeters"

grep -F -q 'wmbusmeters exposes neither --listdrivers nor --listmeters' "${DOCKERFILE}" \
  || fail "Dockerfile must fail loudly if both driver-list options disappear"
grep -F -q '"driver":"izar"' "${DOCKERFILE}" \
  || fail "Dockerfile must assert that built-in izar remains in drivers.json"

echo "PASS: Dockerfile driver catalog keeps built-in driver coverage"
