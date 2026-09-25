#!/usr/bin/env bash
# A retained <diag>/boot redelivered on resubscribe must not be logged as a
# restart. The diag subscriber reconnects every 180 s (mosquitto_sub -W is a
# hard limit), so before the guard a board with 11 h of uptime showed a Boot
# row every three minutes and lost its suggestion panel each time
# (reported on a Heltec V4-R8, 2026-09-25).
# The grep patterns below match literal "${...}" text in the library.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/rootfs/usr/bin/bridge-lib/13-esp.sh"
# shellcheck source=rootfs/usr/bin/bridge-lib/13-esp.sh
source "${LIB}"

BOOT_A='{"event":"boot","radio":"SX1262","listen_mode":"T1","uptime_ms":5123}'
BOOT_B='{"event":"boot","radio":"SX1262","listen_mode":"T1","uptime_ms":4987}'

declare -A _ESP_BOOT_SEEN=()

_esp_boot_is_new wmbus/heltec/diag/boot "${BOOT_A}" \
  || { echo "FAIL: first boot of a board must be new" >&2; exit 1; }

# Resubscribe: the broker hands back the same retained boot.
for _ in 1 2 3; do
  if _esp_boot_is_new wmbus/heltec/diag/boot "${BOOT_A}"; then
    echo "FAIL: retained boot redelivered on resubscribe counted as a restart" >&2; exit 1
  fi
done

# The firmware sends the same payload on the bare diag topic too.
if _esp_boot_is_new wmbus/heltec/diag "${BOOT_A}"; then
  echo "FAIL: bare-diag copy of the same boot counted separately" >&2; exit 1
fi

# Another board with a byte-identical payload is still its own boot.
_esp_boot_is_new wmbus/lilygo/diag/boot "${BOOT_A}" \
  || { echo "FAIL: identical payload from another board suppressed" >&2; exit 1; }

# A real restart carries a different uptime and must get through.
_esp_boot_is_new wmbus/heltec/diag/boot "${BOOT_B}" \
  || { echo "FAIL: genuine restart suppressed" >&2; exit 1; }

# The guard is only useful if the subscriber applies it before logging the
# event and before the boot branch clears the suggestion file.
_guard="$(grep -n '_esp_boot_is_new "\${_etopic}"' "${LIB}" | head -n1 | cut -d: -f1)"
_log="$(grep -n '>> "\${STATUS_ESP_EVENTS_FILE}"' "${LIB}" | head -n1 | cut -d: -f1)"
_rm="$(grep -n 'rm -f "\${STATUS_ESP_SUGGESTION_FILE}"' "${LIB}" | head -n1 | cut -d: -f1)"
_decl="$(grep -n 'declare -A _ESP_BOOT_SEEN' "${LIB}" | head -n1 | cut -d: -f1)"
[[ -n "${_guard}" && -n "${_log}" && -n "${_rm}" && -n "${_decl}" ]] \
  || { echo "FAIL: boot guard wiring not found in 13-esp.sh" >&2; exit 1; }
(( _decl < _guard && _guard < _log && _guard < _rm )) \
  || { echo "FAIL: boot guard must run before the event is logged" >&2; exit 1; }

echo "OK: ESP boot dedup"
