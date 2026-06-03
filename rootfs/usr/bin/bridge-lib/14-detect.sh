#!/usr/bin/env bash
# Dedicated manufacturer-detection LISTEN instance.
#
# Problem this solves: the primary DECODE pipeline (configured meters) emits
# JSON, which carries no manufacturer name, and the parallel LISTEN instance is
# loaded with meter-preview-<id> files for candidates. Once a wmbusmeters
# instance has >=1 meter it leaves "Printing id:s of all telegrams heard!" mode
# and no longer prints the "Received telegram from: / manufacturer:" analysis
# block for telegrams that match no configured/preview meter. Officially
# configured meters are pruned from the preview dir (and AES meters never get a
# preview at all), so their full manufacturer text is never (re)captured while
# meters are configured. The WebGUI configured-meters panel borrows the
# manufacturer from the candidate row, which then keeps only the bare 3-letter
# code filled by the RAW M-field path.
#
# This instance runs wmbusmeters against a config dir that NEVER contains a
# meter file, so it stays permanently in "print all telegrams" mode and always
# emits the manufacturer analysis block for every telegram heard. The parser
# updates ONLY the manufacturer column of an EXISTING candidate row (via
# candidate_update_manufacturer_text). It does NOT touch reception stats,
# preview values, candidate analysis or events, so it cannot double-count
# anything the primary or parallel pipelines already track.

DETECT_PID=""

# Parse pure-listen text output and heal the manufacturer column only.
# Delayed flush on the next "Received telegram from:" so the manufacturer:
# line (which follows the header) is captured before the block is dispatched.
parse_detect_manufacturer() {
  local last_id="" last_mfr="" line new_id
  while IFS= read -r line; do
    if [[ "${line}" =~ ^Received\ telegram\ from:\ ([0-9A-Fa-f]{8}) ]]; then
      # Capture the match BEFORE the flush — candidate_update_manufacturer_text
      # runs its own [[ =~ ]] internally, which clobbers BASH_REMATCH.
      new_id="${BASH_REMATCH[1]}"
      [[ -n "${last_id}" && -n "${last_mfr}" ]] \
        && candidate_update_manufacturer_text "${last_id}" "${last_mfr}"
      last_id="$(normalize_meter_id "${new_id}")"
      last_mfr=""
    elif [[ "${line}" =~ ^[[:space:]]*manufacturer:[[:space:]]*(.*)$ ]]; then
      last_mfr="${BASH_REMATCH[1]}"
    fi
  done
  # Flush the final block after the stream ends.
  [[ -n "${last_id}" && -n "${last_mfr}" ]] \
    && candidate_update_manufacturer_text "${last_id}" "${last_mfr}"
}

start_detect_instance() {
  # Idempotent — already running?
  if [[ -n "${DETECT_PID}" ]] && kill -0 "${DETECT_PID}" 2>/dev/null; then
    return 0
  fi
  (
    # Supervisor loop: restart the pure-listen pipeline if it ever exits.
    # No .reload handling — the detect config never changes (always 0 meters).
    while true; do
      ${STDBUF_BIN} /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" "${SUB_EXTRA[@]}" -t "${RAW_TOPIC}" -F '%p' \
        | awk '
            function ishex(s) { return (s ~ /^[0-9A-Fa-f]+$/) }
            {
              gsub(/[[:space:]]/, "", $0);
              sub(/^0x/i, "", $0);
              if (!ishex($0)) next;
              if ((length($0) % 2) != 0) next;
              print $0;
              fflush();
            }
          ' \
        | ${STDBUF_BIN} /usr/bin/wmbusmeters --useconfig="${DETECT_BASE}" 2>&1 \
        | parse_detect_manufacturer &
      detect_pipeline_pid=$!
      wait "${detect_pipeline_pid}" 2>/dev/null || true
      # Brief pause before restart to avoid tight-looping on persistent failures.
      sleep 1
    done
  ) &
  DETECT_PID=$!
  log "Manufacturer-detection LISTEN instance started (pid=${DETECT_PID}) — pure listen, zero meters, heals candidate manufacturer."
}

stop_detect_instance() {
  [[ -z "${DETECT_PID}" ]] && return 0
  log "Stopping manufacturer-detection LISTEN instance (pid=${DETECT_PID})..."
  pkill -TERM -P "${DETECT_PID}" 2>/dev/null || true
  kill -TERM "${DETECT_PID}" 2>/dev/null || true
  wait "${DETECT_PID}" 2>/dev/null || true
  pkill -KILL -P "${DETECT_PID}" 2>/dev/null || true
  DETECT_PID=""
}
