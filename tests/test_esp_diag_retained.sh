#!/usr/bin/env bash
# Retained diag topics replayed on resubscribe must not reach the event log.
# The broker replays every retained topic on each subscribe - at start, after a
# reconnect, and every 180 s while the subscriber used -W 180 (a hard limit),
# each time stamped as new. Stale
# LR1121 debug samples (lr_fifo/lr_drop) refilled the log, and a board removed
# weeks earlier kept "pulse stopped" raised through its retained topics.
# The grep patterns below match literal "${...}" text in the library.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/rootfs/usr/bin/bridge-lib/13-esp.sh"
# shellcheck source=rootfs/usr/bin/bridge-lib/13-esp.sh
source "${LIB}"

_esp_diag_replay_ignored 1 \
  || { echo "FAIL: retained replay would be logged as new" >&2; exit 1; }
if _esp_diag_replay_ignored 0; then
  echo "FAIL: live diag message dropped" >&2; exit 1
fi

# The guard needs the retained flag from mosquitto_sub.
grep -qF -- "-F '%r\t%t\t%p' 2>/dev/null" "${LIB}" \
  || { echo "FAIL: diag subscriber does not request the retained flag (%r)" >&2; exit 1; }

# The config snapshot is retained on purpose (the bridge learns each board's
# settings on subscribe), so it must be stored before the guard drops replays,
# and the event log must be written only after the guard.
_cfg="$(grep -nF 'if [[ "${_etopic}" == wmbus/*/diag/config ]]' "${LIB}" | head -n1 | cut -d: -f1)"
_guard="$(grep -nF 'if _esp_diag_replay_ignored "${_eretained}"' "${LIB}" | head -n1 | cut -d: -f1)"
_log="$(grep -nF '>> "${STATUS_ESP_EVENTS_FILE}"' "${LIB}" | head -n1 | cut -d: -f1)"
[[ -n "${_cfg}" && -n "${_guard}" && -n "${_log}" ]] \
  || { echo "FAIL: retained guard wiring not found in 13-esp.sh" >&2; exit 1; }
(( _cfg < _guard && _guard < _log )) \
  || { echo "FAIL: config must be stored before, and the log written after, the retained guard" >&2; exit 1; }

# The long-lived subscribers stay connected: a -W timeout is a hard limit, so
# with it each one reconnected every 90 or 180 s - broker connections, logins
# and retained replays for nothing. Short probes elsewhere keep theirs.
if grep -nE 'mosquitto_sub .*-W [0-9]+' "${LIB}"; then
  echo "FAIL: a long-lived ESP subscriber has a -W timeout again" >&2; exit 1
fi

echo "OK: ESP retained diag replay"
