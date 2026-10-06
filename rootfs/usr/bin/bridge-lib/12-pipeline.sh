#!/usr/bin/env bash
# MQTT publish and pipeline startup helpers.

mqtt_pub() {
  local topic="$1"
  local payload="$2"
  local retain="${3:-false}"

  if [[ -n "${MQTT_PUB_PORT:-}" ]]; then
    local _r=0
    [[ "${retain}" == "true" ]] && _r=1
    _mqtt_pub_persistent "${topic}" "${payload}" "${_r}" && return 0
  fi

  # No persistent publisher (disabled, not started, or not answering): one
  # mosquitto_pub per message, as before it existed.
  local retain_flag=()
  [[ "${retain}" == "true" ]] && retain_flag=( -r )

  "${MOSQUITTO_PUB_BIN:-/usr/bin/mosquitto_pub}" "${PUB_ARGS[@]}" -t "${topic}" "${retain_flag[@]}" -m "${payload}" || true
}

# Hand one message to mqtt_publisher.py over loopback TCP ($1 topic, $2
# payload, $3 retain 0/1). /dev/tcp is bash's own, so this execs nothing. It
# runs in a subshell for two reasons: a publisher dying between accept and
# write raises SIGPIPE, which then ends this subshell (the message falls back
# to mosquitto_pub) instead of the process that publishes - the decode loop,
# the heartbeat ticker; and LC_ALL=C there makes ${#2} count bytes, which is
# what the frame header carries.
_mqtt_pub_persistent() {
  (
    exec 3>"/dev/tcp/127.0.0.1/${MQTT_PUB_PORT}" || exit 1
    LC_ALL=C
    printf 'PUB %s %s %s\n%s\n' "$3" "${#2}" "$1" "$2" >&3 || exit 1
  ) 2>/dev/null
}

# Start mqtt_publisher.py: one broker connection kept open for every publish
# of the add-on, instead of a mosquitto_pub (process + connection + login) per
# message. Called once from the main shell, before any process that publishes
# is forked, so MQTT_PUB_PORT is inherited by all of them. The loop restarts
# the publisher if it exits; it binds the same port again (port file), so the
# writers keep working. MQTT_PERSISTENT_PUBLISHER=false falls back to
# mosquitto_pub per message.
MQTT_PUB_PORT=""
MQTT_PUB_DEC="false"
MQTT_PUBLISHER_PID=""
start_mqtt_publisher() {
  if [[ "${MQTT_PERSISTENT_PUBLISHER:-true}" != "true" ]]; then
    log "MQTT: persistent publisher disabled, using mosquitto_pub per message"
    return 0
  fi
  local port_file="${RUNTIME:-${BASE}}/mqtt_publisher.port"
  local script="${MQTT_PUBLISHER:-${BRIDGE_SCRIPT_DIR:-/usr/bin}/mqtt_publisher.py}"
  rm -f "${port_file}" 2>/dev/null || true
  (
    while true; do
      # Credentials through the environment: argv is visible in ps. So is the
      # configuration wmbus_discovery.py needs to build Discovery the way
      # emit_discovery_from_json does.
      MQTT_USER="${MQTT_USER}" MQTT_PASS="${MQTT_PASS}" \
      DISCOVERY_ENABLED="${DISCOVERY_ENABLED:-true}" DISCOVERY_PREFIX="${DISCOVERY_PREFIX:-homeassistant}" \
      DISCOVERY_RETAIN="${DISCOVERY_RETAIN:-true}" STATE_PREFIX="${STATE_PREFIX:-wmbusmeters}" \
      STATE_RETAIN="${STATE_RETAIN:-false}" REQUIRE_TIMESTAMP="${REQUIRE_TIMESTAMP:-false}" \
      STATUS_RSSI_FILE="${STATUS_RSSI_FILE:-}" STATUS_SEEN_FILE="${STATUS_SEEN_FILE:-}" \
      RSSI_MAX_AGE_S="${RSSI_MAX_AGE_S:-300}" WMBUSMETERS_BIN="${WMBUSMETERS_BIN:-/usr/bin/wmbusmeters}" \
        python3 "${script}" --host "${MQTT_HOST}" --port "${MQTT_PORT}" --port-file "${port_file}"
      warn "MQTT: persistent publisher exited (rc=$?), restarting in 2s"
      sleep 2
    done
  ) &
  # shellcheck disable=SC2034  # for whoever has to stop it (the tests do)
  MQTT_PUBLISHER_PID=$!

  local _i _port="" _caps=""
  for (( _i = 0; _i < 50; _i++ )); do
    [[ -s "${port_file}" ]] && read -r _port _caps < "${port_file}"
    [[ "${_port}" =~ ^[0-9]+$ ]] && break
    _port=""
    sleep 0.1
  done
  if [[ -z "${_port}" ]]; then
    warn "MQTT: persistent publisher did not start, using mosquitto_pub per message"
    return 0
  fi
  MQTT_PUB_PORT="${_port}"
  # "dec": the publisher builds Discovery and state of decoded telegrams
  # itself (wmbus_discovery.py). Without it publish_decoded_json does it here.
  if [[ " ${_caps} " == *" dec "* && "${MQTT_PYTHON_DISCOVERY:-true}" == "true" ]]; then
    MQTT_PUB_DEC="true"
  fi
  log "MQTT: persistent publisher ready (one broker connection for all publishes; Discovery in Python: ${MQTT_PUB_DEC})"
}

# Hand one decoded telegram to the publisher ($1 exclude patterns of its meter,
# $2 the JSON line); same subshell and byte count as _mqtt_pub_persistent.
_mqtt_dec_persistent() {
  (
    exec 3>"/dev/tcp/127.0.0.1/${MQTT_PUB_PORT}" || exit 1
    LC_ALL=C
    local _payload="$1"$'\n'"$2"
    printf 'DEC %s\n%s\n' "${#_payload}" "${_payload}" >&3 || exit 1
  ) 2>/dev/null
}

# A new decode pipeline starts with empty Discovery caches, in bash because
# they live in the pipeline's subshell; this tells the publisher the same.
mqtt_reset_discovery() {
  [[ "${MQTT_PUB_DEC}" == "true" ]] || return 0
  ( exec 3>"/dev/tcp/127.0.0.1/${MQTT_PUB_PORT}" && printf 'RST\n' >&3 ) 2>/dev/null || true
}

# Publish one decoded telegram of a configured meter: its Discovery configs
# and its state. Both decode branches of run_once (FILTER_HEX_ONLY on/off) call
# this, and tests/test_publish_contract.sh records everything it publishes.
publish_decoded_json() {
  local line="$1" id ts
  # The publisher builds Discovery and state itself (wmbus_discovery.py): it
  # needs only the meter's exclude patterns, looked up here because
  # METER_EXCLUDE_FIELDS is filled by bash (options, M-Bus) and keyed by the
  # lower-case normalized id. The id is read with a regex, not jq - this runs
  # for every decoded telegram. If the hand-over fails, the bash path below
  # publishes instead.
  if [[ "${MQTT_PUB_DEC}" == "true" ]]; then
    local _patterns="" _key=""
    if (( ${#METER_EXCLUDE_FIELDS[@]} )) && [[ "${line}" =~ \"id\":\"?([^\",}]*) ]]; then
      _key="$(normalize_meter_id "${BASH_REMATCH[1]}")"
      _key="${_key,,}"
      [[ -n "${_key}" ]] && _patterns="${METER_EXCLUDE_FIELDS[${_key}]:-}"
    fi
    if _mqtt_dec_persistent "${_patterns}" "${line}"; then
      status_mark_discovery_published
      write_status_json
      return 0
    fi
  fi
  id="$(normalize_meter_id "$(echo "${line}" | jq -r '.id // empty' 2>/dev/null || true)")"
  ts="$(echo "${line}" | jq -r '.timestamp // .device_date_time // empty' 2>/dev/null || true)"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  if [[ "${REQUIRE_TIMESTAMP}" == "true" && -z "${ts}" ]]; then
    warn "Skip publish: missing timestamp for id=${id}"
    return 0
  fi
  # Join the opt-in per-meter RSSI before both the Discovery config and the
  # state payload, so the field is seen by the same machinery as every decoded
  # field and needs no special case downstream.
  line="$(inject_rssi_into_json "${id}" "${line}")"
  emit_discovery_from_json "${line}"
  mqtt_pub "${STATE_PREFIX}/${id}/state" "${line}" "${STATE_RETAIN}" || true
  status_mark_discovery_published
  write_status_json
}

wait_for_mqtt() {
  log "Waiting for MQTT broker ${MQTT_HOST}:${MQTT_PORT}..."
  local _wm_out _wm_code _wm_prev
  for ((i=1; i<=MQTT_WAIT_RETRIES; i++)); do
    # Capture stderr instead of --quiet: mosquitto's error text is the only
    # way to tell "broker down" apart from "broker up but credentials
    # rejected" — those two need different retry cadences and different
    # WebUI messages.
    if _wm_out="$(/usr/bin/mosquitto_pub "${PUB_ARGS[@]}" -t "wmbus_bridge/status" -m "starting" 2>&1)"; then
      log "MQTT broker ready (attempt ${i}/${MQTT_WAIT_RETRIES})"
      STATUS_MQTT_CONNECTED="true"
      STATUS_LAST_ERROR=""
      # Connection works again — clear the broker-error marker so the WebUI
      # banner disappears.
      if [[ -s "${STATUS_BROKER_ERROR_FILE}" ]]; then
        : > "${STATUS_BROKER_ERROR_FILE}" 2>/dev/null || true
      fi
      status_add_event "ok" "MQTT broker ready"
      write_status_json
      return 0
    fi
    _wm_code="unreachable"
    if grep -qiE 'not authori[sz]ed|bad user ?name or password' <<<"${_wm_out}"; then
      _wm_code="auth_rejected"
    fi
    # Marker for the WebUI banner: code<TAB>host:port. Written on every failed
    # attempt (cheap); the event is emitted only when the classification
    # changes, so the event log is not flooded across retry cycles.
    _wm_prev="$(head -n1 "${STATUS_BROKER_ERROR_FILE}" 2>/dev/null || true)"
    printf '%s\t%s\n' "${_wm_code}" "${MQTT_HOST}:${MQTT_PORT}" > "${STATUS_BROKER_ERROR_FILE}.tmp" 2>/dev/null \
      && mv "${STATUS_BROKER_ERROR_FILE}.tmp" "${STATUS_BROKER_ERROR_FILE}" 2>/dev/null || true
    if [[ "${_wm_prev%%$'\t'*}" != "${_wm_code}" && "${_wm_code}" == "auth_rejected" ]]; then
      status_add_event "error" "MQTT broker rejected the credentials — check external_mqtt_username/password"
    fi
    if [[ "${_wm_code}" == "auth_rejected" ]]; then
      # A broker that actively rejects the password will keep rejecting it —
      # retry slowly instead of hammering it (with a wrong password this
      # add-on once produced ~200 authentication failures per minute against
      # EMQX, throttled in the broker's own log).
      warn "MQTT broker REJECTED the credentials (attempt ${i}/${MQTT_WAIT_RETRIES}), retrying in $((MQTT_WAIT_DELAY * 5))s..."
      sleep "$((MQTT_WAIT_DELAY * 5))"
    else
      warn "MQTT not ready (attempt ${i}/${MQTT_WAIT_RETRIES}), retrying in ${MQTT_WAIT_DELAY}s..."
      sleep "${MQTT_WAIT_DELAY}"
    fi
  done
  # Broker niedostępny po wszystkich próbach - ostrzegamy ale nie przerywamy,
  # pętla restart_on_exit zajmie się ponownym uruchomieniem pipeline.
  warn "MQTT broker not available after ${MQTT_WAIT_RETRIES} attempts, continuing anyway..."
  # shellcheck disable=SC2034
  STATUS_MQTT_CONNECTED="false"
  # shellcheck disable=SC2034
  STATUS_LAST_ERROR="MQTT broker not available"
  status_add_event "error" "MQTT broker not available"
  write_status_json
  return 1
}
