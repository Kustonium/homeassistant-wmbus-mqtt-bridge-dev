#!/usr/bin/env bash
# Regression test: discovery must be emitted before the matching state payload.
# With state_retain=false, publishing state first can leave freshly discovered
# HA entities unavailable until another telegram arrives.
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
[[ "${SCRIPT_DIR}" == "${SCRIPT_PATH}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BRIDGE_SH="${ROOT_DIR}/rootfs/usr/bin/bridge.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mapfile -t discovery_lines < <(grep -n -F 'emit_discovery_from_json "${line}"' "${BRIDGE_SH}" | cut -d: -f1)
mapfile -t state_lines < <(grep -n -F 'mqtt_pub "${STATE_PREFIX}/${id}/state"' "${BRIDGE_SH}" | cut -d: -f1)

[[ "${#discovery_lines[@]}" -eq 2 ]] || fail "expected two discovery emits, got ${#discovery_lines[@]}"
[[ "${#state_lines[@]}" -eq 2 ]] || fail "expected two state publishes, got ${#state_lines[@]}"

for i in "${!state_lines[@]}"; do
  discovery_line="${discovery_lines[${i}]}"
  state_line="${state_lines[${i}]}"
  (( discovery_line < state_line )) \
    || fail "state publish at line ${state_line} occurs before discovery at line ${discovery_line}"
  (( state_line - discovery_line <= 3 )) \
    || fail "state publish at line ${state_line} is not paired with nearby discovery at line ${discovery_line}"
done

echo "PASS: bridge publishes discovery before state in both decode paths"
