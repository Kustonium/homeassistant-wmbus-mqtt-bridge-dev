#!/usr/bin/env bash
# Regression test: discovery must be emitted before the matching state payload.
# With state_retain=false, publishing state first can leave freshly discovered
# HA entities unavailable until another telegram arrives.
#
# Both decode paths of bridge.sh hand a decoded telegram to
# publish_decoded_json (12-pipeline.sh); this checks that both do, and that the
# function emits Discovery before the state. tests/test_publish_contract.sh
# checks the resulting publish order end to end.
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
[[ "${SCRIPT_DIR}" == "${SCRIPT_PATH}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BRIDGE_SH="${ROOT_DIR}/rootfs/usr/bin/bridge.sh"
PIPELINE_SH="${ROOT_DIR}/rootfs/usr/bin/bridge-lib/12-pipeline.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

calls="$(grep -c -F 'publish_decoded_json "${line}"' "${BRIDGE_SH}" || true)"
[[ "${calls}" -eq 2 ]] || fail "expected both decode paths to call publish_decoded_json, got ${calls}"
grep -q -F 'mqtt_pub "${STATE_PREFIX}/${id}/state"' "${BRIDGE_SH}" \
  && fail "bridge.sh publishes a meter state itself instead of through publish_decoded_json"

body="$(sed -n '/^publish_decoded_json() {/,/^}/p' "${PIPELINE_SH}")"
[[ -n "${body}" ]] || fail "publish_decoded_json not found in 12-pipeline.sh"
discovery_line="$(grep -n -F 'emit_discovery_from_json "${line}"' <<<"${body}" | cut -d: -f1)"
state_line="$(grep -n -F 'mqtt_pub "${STATE_PREFIX}/${id}/state"' <<<"${body}" | cut -d: -f1)"
[[ -n "${discovery_line}" && -n "${state_line}" ]] \
  || fail "publish_decoded_json must emit Discovery and publish the state"
(( discovery_line < state_line )) \
  || fail "publish_decoded_json publishes the state before Discovery"

echo "PASS: both decode paths publish Discovery before state (publish_decoded_json)"
