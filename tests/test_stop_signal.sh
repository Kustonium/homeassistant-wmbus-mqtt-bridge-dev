#!/usr/bin/env bash
# Regression test: SIGTERM ends bridge.sh.
#
# The stop handler of bridge.sh only returned, so after SIGTERM the restart
# loop started the pipeline again ("Pipeline exited cleanly, reloading in
# 2s...") until s6 gave up waiting ("s6-svwait: fatal: timed out") and killed
# it - and the last save of the RAM status directory depends on that handler.
# This runs the real handler block of bridge.sh (from "_STOPPED=0" to the
# TERM trap) on the same loop shape, sends SIGTERM to its process group and
# checks that the script ends, after running the stop work exactly once.
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
[[ "${SCRIPT_DIR}" == "${SCRIPT_PATH}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd)"
BRIDGE_SH="${SCRIPT_DIR}/../rootfs/usr/bin/bridge.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
command -v setsid >/dev/null 2>&1 || { echo "SKIP: setsid not available"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

block="$(sed -n '/^_STOPPED=0$/,/^trap _on_stop_signal TERM INT$/p' "${BRIDGE_SH}")"
[[ "${block}" == *"trap _on_stop_signal TERM INT"* ]] || fail "stop handler block not found in bridge.sh"

{
  echo 'set -euo pipefail'
  echo "stop_listen_instance() { echo listen >> '${TMP}/stops'; }"
  echo 'stop_mbus_instance() { :; }'
  echo "runtime_snapshot() { echo snapshot >> '${TMP}/stops'; }"
  echo 'sleep() { command sleep 0.1; }'  # the handler's pause, shortened
  printf '%s\n' "${block}"
  echo 'while true; do set +e; command sleep 30 | cat; echo reloading >> '"'${TMP}/stops'"'; done'
} > "${TMP}/bridge-loop.sh"

setsid bash "${TMP}/bridge-loop.sh" > "${TMP}/out" 2>&1 < /dev/null &
pid=$!
command sleep 1
kill -TERM -- "-${pid}" 2>/dev/null || kill -TERM "${pid}"
for _ in $(seq 1 30); do
  kill -0 "${pid}" 2>/dev/null || break
  command sleep 0.1
done
if kill -0 "${pid}" 2>/dev/null; then
  kill -9 -- "-${pid}" 2>/dev/null || true
  fail "bridge.sh still runs 3 s after SIGTERM ($(tr '\n' ' ' < "${TMP}/stops" 2>/dev/null))"
fi
stops="$(tr '\n' ' ' < "${TMP}/stops")"
[[ "${stops}" == "listen snapshot " ]] \
  || fail "stop work ran as '${stops}', expected 'listen snapshot ' once and no reload"
echo "PASS: SIGTERM ends bridge.sh after the stop work ran once (LISTEN stopped, RAM directory saved)"
