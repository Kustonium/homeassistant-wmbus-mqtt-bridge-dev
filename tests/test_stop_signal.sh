#!/usr/bin/env bash
# Regression test: stopping the add-on ends bridge.sh promptly.
#
# Two things kept bridge.sh running after SIGTERM:
# - its handler only returned, so the restart loop started the pipeline again
#   ("Pipeline exited cleanly, reloading in 2s...");
# - s6 signals the service process only, and bash runs a trap only once the
#   foreground pipeline it waits on ends - so the handler sat there until s6
#   gave up ("s6-svwait: fatal: timed out") and killed everything, the last
#   save of the RAM status directory included.
# This runs the real handler block of bridge.sh (from "_STOPPED=0" to the TERM
# trap) on the restart loop's shape, under the real launch block of run.sh
# (from "setsid /usr/bin/bridge.sh &" to its exit), sends SIGTERM to the
# launcher only, as s6 does, and checks that the loop ends within 3 s after
# running the stop work exactly once. A second case sends SIGTERM to the loop's
# own process group directly (Docker's entrypoint).
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
[[ "${SCRIPT_DIR}" == "${SCRIPT_PATH}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BRIDGE_SH="${ROOT_DIR}/rootfs/usr/bin/bridge.sh"
RUN_SH="${ROOT_DIR}/rootfs/usr/bin/run.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
command -v setsid >/dev/null 2>&1 || { echo "SKIP: setsid not available"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

handler="$(sed -n '/^_STOPPED=0$/,/^trap _on_stop_signal TERM INT$/p' "${BRIDGE_SH}")"
[[ "${handler}" == *"trap _on_stop_signal TERM INT"* ]] || fail "stop handler block not found in bridge.sh"
launcher="$(sed -n '/^setsid \/usr\/bin\/bridge.sh &$/,/^exit "\${rc}"$/p' "${RUN_SH}")"
[[ "${launcher}" == *'exit "${rc}"'* ]] || fail "bridge.sh launch block not found in run.sh"

# The bridge: the handler block on the restart loop, the pipeline in the
# foreground as in run_once.
{
  echo 'set -euo pipefail'
  echo "log() { echo \"\$*\" >> '${TMP}/log'; }"
  echo "stop_listen_instance() { echo listen >> '${TMP}/stops'; }"
  echo 'stop_mbus_instance() { :; }'
  echo "runtime_snapshot() { echo snapshot >> '${TMP}/stops'; }"
  echo 'sleep() { command sleep 0.1; }'  # the handler's pause, shortened
  printf '%s\n' "${handler}"
  echo 'while true; do set +e; command sleep 30 | while read -r _; do :; done; echo reloading >> '"'${TMP}/stops'"'; done'
} > "${TMP}/bridge.sh"
# The launcher: run.sh's block, starting the bridge above.
{
  echo 'set -euo pipefail'
  printf '%s\n' "${launcher//\/usr\/bin\/bridge.sh/bash ${TMP}/bridge.sh}"
} > "${TMP}/run.sh"

check() {  # $1 = case name
  local stops
  stops="$(tr '\n' ' ' < "${TMP}/stops" 2>/dev/null || true)"
  [[ "${stops}" == "listen snapshot " ]] \
    || fail "$1: stop work ran as '${stops}', expected 'listen snapshot ' once and no reload"
  grep -q '^stop: SIGTERM received' "${TMP}/log" || fail "$1: the stop was not logged"
}
wait_gone() {  # $1 = pid; true when it is gone within 3 s
  for _ in $(seq 1 30); do
    kill -0 "$1" 2>/dev/null || return 0
    command sleep 0.1
  done
  return 1
}

# 1) s6: SIGTERM to the service process (run.sh) only.
setsid bash "${TMP}/run.sh" > "${TMP}/out" 2>&1 < /dev/null &
run_pid=$!
command sleep 1
kill -TERM "${run_pid}"
if ! wait_gone "${run_pid}"; then
  kill -9 -- "-${run_pid}" 2>/dev/null || true
  pkill -9 -f "${TMP}/bridge.sh" 2>/dev/null || true
  fail "s6 stop: still running 3 s after SIGTERM to run.sh ($(tr '\n' ' ' < "${TMP}/stops" 2>/dev/null))"
fi
pgrep -f "${TMP}/bridge.sh" >/dev/null && fail "s6 stop: run.sh exited but bridge.sh still runs"
check "s6 stop"

# 2) Docker: SIGTERM to the bridge's process group.
rm -f "${TMP}/stops" "${TMP}/log"
setsid bash "${TMP}/bridge.sh" > "${TMP}/out" 2>&1 < /dev/null &
pid=$!
command sleep 1
kill -TERM -- "-${pid}" 2>/dev/null || kill -TERM "${pid}"
if ! wait_gone "${pid}"; then
  kill -9 -- "-${pid}" 2>/dev/null || true
  fail "group stop: still running 3 s after SIGTERM ($(tr '\n' ' ' < "${TMP}/stops" 2>/dev/null))"
fi
check "group stop"

echo "PASS: SIGTERM to run.sh (s6) or to the bridge's group (Docker) ends bridge.sh within 3 s, stop work done once"
