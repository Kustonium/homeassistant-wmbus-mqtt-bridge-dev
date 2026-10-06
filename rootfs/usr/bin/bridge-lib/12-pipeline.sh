#!/usr/bin/env bash
# MQTT publish and pipeline startup helpers.

mqtt_pub() {
  local topic="$1"
  local payload="$2"
  local retain="${3:-false}"

  local retain_flag=()
  [[ "${retain}" == "true" ]] && retain_flag=( -r )

  /usr/bin/mosquitto_pub "${PUB_ARGS[@]}" -t "${topic}" "${retain_flag[@]}" -m "${payload}" || true
}

# Publish one decoded telegram of a configured meter: its Discovery configs
# and its state. Both decode branches of run_once (FILTER_HEX_ONLY on/off) call
# this, and tests/test_publish_contract.sh records everything it publishes.
publish_decoded_json() {
  local line="$1" id ts
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
