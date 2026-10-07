#!/usr/bin/env bash
# Regression test: bridge.sh must not empty status_candidate_values.tsv at start.
#
# The preview state of a candidate (status_candidate_preview_state.tsv) comes
# back from the runtime snapshot after a restart. When the values file next to
# it was emptied at start, an already decoded candidate showed "decoding..." in
# the WebUI until its next telegram - up to an hour for a meter that sends
# rarely (seen on a test install: last telegram 11:48, restart 12:02, interval
# ~45 min). Both files have to survive a restart together.
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
[[ "${SCRIPT_DIR}" == "${SCRIPT_PATH}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd)"
BRIDGE_SH="${SCRIPT_DIR}/../rootfs/usr/bin/bridge.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Any truncation of the file in bridge.sh: ": > FILE", "> FILE", "echo -n > FILE".
# The grep pattern matches the literal "${...}" text.
# shellcheck disable=SC2016
if grep -nE '(^|[;&|[:space:]])(:[[:space:]]*)?>[[:space:]]*"\$\{STATUS_CANDIDATE_VALUES_FILE\}"' "${BRIDGE_SH}"; then
  fail "bridge.sh empties status_candidate_values.tsv; preview values must survive a restart with their state"
fi
grep -q 'touch "${STATUS_CANDIDATE_VALUES_FILE}"' "${BRIDGE_SH}" \
  || fail "bridge.sh no longer creates status_candidate_values.tsv at start"

echo "PASS: preview values survive a restart together with the preview state"
