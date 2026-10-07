#!/usr/bin/env bash
# Regression test: discovery must be emitted before the matching state payload.
# With state_retain=false, publishing state first can leave freshly discovered
# HA entities unavailable until another telegram arrives.
#
# Both decode paths of bridge.sh read the decoder through _decode_stage
# (12-pipeline.sh), whose bash loop (_decode_consume_bash) and fallback hand a
# decoded telegram to publish_decoded_json; bridge_ledger.py decode hands it to
# the publisher, whose Discovery is built the same way (wmbus_discovery.py).
# This checks those calls, and that publish_decoded_json emits Discovery before
# the state. tests/test_publish_contract.sh checks the resulting publish order
# end to end, tests/test_decode_stage.py the two loops against each other.
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

calls="$(grep -c -E '\| _decode_stage (true|false)$' "${BRIDGE_SH}" || true)"
[[ "${calls}" -eq 2 ]] || fail "expected both decode paths to read the decoder through _decode_stage, got ${calls}"
loop="$(sed -n '/^_decode_consume_bash() {/,/^}/p' "${PIPELINE_SH}")"
grep -q -F 'publish_decoded_json "${line}"' <<<"${loop}" \
  || fail "_decode_consume_bash does not hand decoded telegrams to publish_decoded_json"
stage="$(sed -n '/^_decode_stage() {/,/^}/p' "${PIPELINE_SH}")"
grep -q -F 'publish_decoded_json "${_d}"' <<<"${stage}" \
  || fail "_decode_stage's fallback does not hand telegrams to publish_decoded_json"
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
