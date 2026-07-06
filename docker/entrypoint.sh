#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Docker/LXC wrapper
# - Ensures <base>/options.json exists (default if missing)
# - Reads external MQTT settings from options.json
# - Exports MQTT_* env vars
# - Runs core bridge (/usr/bin/bridge.sh)
# ============================================================

BASE="${WMBUS_BASE:-/config}"
export WMBUS_BASE="${BASE}"

OPTIONS_JSON="${BASE}/options.json"
mkdir -p "${BASE}"

if [[ ! -f "${OPTIONS_JSON}" ]]; then
  cat > "${OPTIONS_JSON}" <<'EOFJSON'
{
  "raw_topic": "wmbus/+/telegram",
  "loglevel": "normal",
  "filter_hex_only": true,
  "debug_every_n": 0,

  "search_mode": false,
  "search_expected_value_m3": 0,
  "search_tolerance_m3": 0.05,
  "search_delta_mode": false,
  "search_min_delta_m3": 0.001,
  "search_topic": "wmbus/search/candidates",

  "discovery_enabled": true,
  "discovery_prefix": "homeassistant",
  "discovery_retain": true,

  "state_prefix": "wmbusmeters",
  "state_retain": false,

  "mqtt_mode": "external",
  "external_mqtt_host": "mosquitto",
  "external_mqtt_port": 1883,
  "external_mqtt_username": "",
  "external_mqtt_password": "",

  "meters": []
}
EOFJSON
  echo "[wmbus-bridge] Created default ${OPTIONS_JSON} (edit it + restart container)."
fi

MQTT_HOST="$(jq -r '.external_mqtt_host // .mqtt.host // "mosquitto"' "${OPTIONS_JSON}")"
MQTT_PORT="$(jq -r '.external_mqtt_port // .mqtt.port // 1883' "${OPTIONS_JSON}")"
MQTT_USER="$(jq -r '.external_mqtt_username // .mqtt.username // ""' "${OPTIONS_JSON}")"
MQTT_PASS="$(jq -r '.external_mqtt_password // .mqtt.password // ""' "${OPTIONS_JSON}")"

export MQTT_HOST MQTT_PORT MQTT_USER MQTT_PASS

WEBUI_PORT="${WEBUI_PORT:-8099}"
export WEBUI_PORT

echo "[wmbus-bridge] Starting WebGUI on port ${WEBUI_PORT}..."
/usr/bin/python3 /usr/bin/webui.py &

echo "[wmbus-bridge] Starting core bridge..."
/usr/bin/bridge.sh &
BRIDGE_PID=$!

# PID 1 must stay THIS shell (no exec): the WebUI restart button in Docker
# mode signals PID 1 with SIGTERM, and that only stops the container when
# PID 1 installs a handler that exits — bridge.sh's own TERM trap
# (stop_listen_instance) cleans up but does not exit, and SIGKILL to PID 1
# from inside the namespace is ignored by the kernel. The container comes
# back only under a restart policy (docker/examples compose:
# restart: unless-stopped); without one, "restart" degrades to "stop".
term_handler() {
  echo "[wmbus-bridge] SIGTERM received — stopping container (the restart policy brings it back if configured)."
  kill -TERM "${BRIDGE_PID}" 2>/dev/null || true
  exit 143
}
trap term_handler TERM INT

wait "${BRIDGE_PID}"
exit $?
