#!/usr/bin/env bash
# A soft reload must not leave the wired M-Bus decoder running.
#
# The soft-reload watcher sends SIGTERM to the main shell's direct children.
# The M-Bus supervisor is one of them; when it was killed there, only the
# supervisor shell died - its wmbusmeters and consumer stayed, stop_mbus_instance
# then found no children of a dead PID, and the restart added a second decoder
# on the same serial port. This runs the M-Bus supervisor shape (a decoder
# piped into _mbus_consume_stage, as start_mbus_instance starts it) under a
# main shell, the soft reload's _soft_reload_kill_children and then
# stop_mbus_instance, as the restart loop does, and counts the decoders left.
set -uo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
[[ "${SCRIPT_DIR}" == "${SCRIPT_PATH}" ]] && SCRIPT_DIR="."
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_DIR="${ROOT_DIR}/rootfs/usr/bin/bridge-lib"

WORK_DIR="$(mktemp -d)"
TAG="mbusdecoder$$"
cleanup() { pkill -f "${TAG}" 2>/dev/null || true; rm -rf "${WORK_DIR}"; }
trap cleanup EXIT

for f in "${LIB_DIR}"/*.sh; do
  # shellcheck source=/dev/null
  source "${f}"
done
# shellcheck disable=SC2034  # read by the sourced functions
{
  BRIDGE_SCRIPT_DIR="${ROOT_DIR}/rootfs/usr/bin"
  MBUS_CONSUMER="${ROOT_DIR}/rootfs/usr/bin/wmbus_mbus.py"
  BASE="${WORK_DIR}"; RUNTIME="${WORK_DIR}"; OPTIONS_JSON="${WORK_DIR}/options.json"
  STATUS_EVENTS_FILE="${WORK_DIR}/events.tsv"; MBUS_LOG="${WORK_DIR}/console.log"
  MBUS_STATUS_FILE="${WORK_DIR}/status_mbus.json"; MBUS_BUS_ALIAS=MAIN
  MBUS_TRAFFIC_STATE=starting; MBUS_METERS_OK=1; MBUS_METERS_SKIPPED=0
  LISTEN_PID=""; HEARTBEAT_PID=""; ESP_SUBSCRIBER_PIDS=""; LOGLEVEL=normal
}
echo '{}' > "${OPTIONS_JSON}"
printf '#!/bin/bash\nexec -a %s sleep 600\n' "${TAG}" > "${WORK_DIR}/decoder"
chmod +x "${WORK_DIR}/decoder"

fail=0
for mode in true false; do
  export MBUS_CONSUMER_IN_PYTHON="${mode}"
  # The supervisor block of start_mbus_instance, the stub for wmbusmeters.
  (
    while true; do
      _t0="$(epoch_now)"
      "${WORK_DIR}/decoder" 2>&1 | _mbus_consume_stage &
      wait "$!" 2>/dev/null || true
      _sub_reconnect_sleep "${_t0}" 1
    done
  ) &
  # shellcheck disable=SC2034  # read by _soft_reload_kill_children and stop_mbus_instance
  MBUS_PID=$!
  sleep 2
  before="$(pgrep -fc "${TAG}" || true)"
  # The soft reload, then the restart loop's stop.
  _soft_reload_kill_children "$$" ""
  sleep 1
  stop_mbus_instance > /dev/null
  sleep 2
  after="$(pgrep -fc "${TAG}" || true)"
  if [[ "${before}" == "1" && "${after}" == "0" ]]; then
    echo "OK: soft reload + stop leaves no M-Bus decoder (consumer in Python: ${mode})"
  else
    echo "FAIL: decoders before ${before}, after ${after} (consumer in Python: ${mode})"
    fail=1
  fi
  pkill -f "${TAG}" 2>/dev/null || true
done
exit "${fail}"
