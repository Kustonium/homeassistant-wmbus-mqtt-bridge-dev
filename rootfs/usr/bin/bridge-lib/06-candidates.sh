# Write or update a per-candidate preview lifecycle state row.
# States: pending | decoded_value | decoded_without_numeric_value | no_decode_result
_set_preview_state() {
  local id="$1" state="$2" note="${3:-}"
  _tsv_upsert "${STATUS_CANDIDATE_PREVIEW_STATE_FILE}" "${id}" \
    "$(printf '%s\t%s\t%s\t%s' "${id}" "${state}" "$(iso_now)" "${note}")"
  # Discard the attempt counter once a terminal decode outcome is known.
  case "${state}" in
    decoded_value|decoded_without_numeric_value|no_decode_result)
      rm -f "${BASE}/.preview_attempts/${id}" 2>/dev/null || true
      ;;
  esac
}

# Debounced .reload_listen trigger — trailing ("settle") debounce with a cap.
#
# During candidate discovery many meter-preview-<id> files are written in a
# burst (one per newly seen id). A per-candidate reload would restart the
# LISTEN pipeline once per new candidate, so it never stays up long enough to
# decode anything. This coalesces a burst into far fewer reloads:
#
#   * Each call stamps the current epoch into .reload_listen_req.
#   * A single background worker (guarded by the atomic mkdir of
#     .reload_listen_pending) waits and fires .reload_listen exactly once when
#     EITHER no new request has arrived for RELOAD_SETTLE_SECONDS (discovery
#     went quiet) OR the worker has run for RELOAD_MAXWAIT_SECONDS (a long burst
#     is force-flushed so early candidates still decode without waiting for the
#     whole replay cycle to finish).
#   * After firing, the worker frees the marker; the next request starts a fresh
#     worker, so reloads are naturally rate-limited to ~one per maxwait during a
#     sustained burst and one final reload once the burst ends.
#
# The supervisor restart loads ALL meter-preview-<id> files present on disk, so
# coalescing never drops a candidate — a preview written during the tiny
# rmdir/touch gap is picked up by the reload it triggered or by the next worker.
#
# The webui manual preview toggle touches .reload_listen directly (webui.py),
# bypassing this debounce, so it stays immediately responsive.
#
# Pending marker: mkdir is atomic on POSIX — exactly one concurrent caller wins
# the race and runs the worker; the others are silently coalesced. Orphaned
# .reload_listen_pending is removed at startup (bridge.sh).
_request_listen_reload() {
  local pending="${BASE}/.reload_listen_pending"
  local req="${BASE}/.reload_listen_req"
  local settle="${RELOAD_SETTLE_SECONDS:-6}"
  local maxwait="${RELOAD_MAXWAIT_SECONDS:-30}"
  printf '%s\n' "$(date +%s 2>/dev/null || echo 0)" > "${req}" 2>/dev/null || true
  if mkdir "${pending}" 2>/dev/null; then
    log_debug "[DIAG] reload_listen: settle worker started (settle=${settle}s maxwait=${maxwait}s)"
    (
      _started="$(date +%s 2>/dev/null || echo 0)"
      while true; do
        sleep "${settle}"
        _r="$(cat "${req}" 2>/dev/null || echo 0)"
        _n="$(date +%s 2>/dev/null || echo 0)"
        if (( _n - _r >= settle )) || (( _n - _started >= maxwait )); then
          break
        fi
        log_debug "[DIAG] reload_listen: still settling (last req $(( _n - _r ))s ago, worker age $(( _n - _started ))s)"
      done
      rmdir "${pending}" 2>/dev/null || true
      touch "${BASE}/.reload_listen" 2>/dev/null || true
      log_debug "[DIAG] reload_listen: fired .reload_listen (coalesced burst)"
    ) 2>/dev/null &
  else
    log_debug "[DIAG] reload_listen: coalesced (settle worker already running)"
  fi
}

status_upsert_candidate_analysis() {
  local id
  local encryption="$2"
  local note="$3"
  local ci="${4:-}"
  local security="${5:-}"
  local raw_len="${6:-0}"
  local last_seen="${7:-}"

  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  [[ -n "${last_seen}" ]] || last_seen="$(iso_now)"

  _tsv_upsert "${STATUS_CANDIDATE_ANALYSIS_FILE}" "${id}" \
    "$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "${id}" "${encryption:-unknown}" "${note:-}" "${ci:-}" "${security:-}" "${raw_len:-0}" "${last_seen}")"
}

candidate_autodecode_file() {
  local id="$1"
  printf '%s/meter-preview-%s' "${LISTEN_METER_DIR}" "${id}"
}

candidate_type_requires_aes() {
  local type_lc
  type_lc="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ "${type_lc}" == *not\ encrypted* || "${type_lc}" == *unencrypted* || "${type_lc}" == *no\ aes* || "${type_lc}" == *no_aes* ]] && return 1
  [[ "${type_lc}" == *encrypted* || "${type_lc}" == *aes* ]]
}

ensure_candidate_autodecode() {
  local id
  local driver="${2:-auto}"
  local type_line="${3:-}"
  local reload="${4:-true}"
  local file tmp

  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  file="$(candidate_autodecode_file "${id}")"

  # Skip preview for officially configured meters — they decode via the primary pipeline.
  # Checked via METER_DIR on disk so the guard works in LISTEN subshell forks where
  # in-memory variables from the parent process are stale after a soft pipeline reload.
  if grep -ql "^id=${id,,}$" "${METER_DIR}"/meter-* 2>/dev/null; then
    if [[ -f "${file}" ]]; then
      rm -f "${file}" 2>/dev/null || true
      rm -f "${BASE}/.preview_attempts/${id}" 2>/dev/null || true
      log "autodecode ${id}: skipped (official meter), pruned orphaned preview"
      [[ "${reload}" == "true" ]] && _request_listen_reload
    fi
    return 0
  fi

  log_debug "[DIAG] autodecode ${id}: file=${file} driver=${driver:-auto} type=${type_line:-?} reload=${reload}"

  if candidate_type_requires_aes "${type_line}"; then
    log_verbose "[DIAG] autodecode ${id}: AES required, skipping preview"
    if [[ -f "${file}" ]]; then
      rm -f "${file}" 2>/dev/null || true
      rm -f "${BASE}/.preview_attempts/${id}" 2>/dev/null || true
      if [[ "${reload}" == "true" ]]; then
        # Preview files live in LISTEN_METER_DIR — only the LISTEN instance
        # needs reloading. Do NOT touch RELOAD_FLAG/.reload_pipeline here: that
        # restarts the main DECODE pipeline on every new candidate (churn loop).
        _request_listen_reload
      fi
    fi
    return 0
  fi

  mkdir -p "${LISTEN_METER_DIR}" 2>/dev/null || true
  tmp="${file}.tmp"
  {
    echo "name=preview_${id}"
    echo "id=${id,,}"
    if [[ -n "${driver}" && "${driver}" != "auto" && "${driver}" != "unknown" ]]; then
      echo "driver=${driver}"
    fi
  } > "${tmp}" 2>/dev/null || return 0

  if [[ ! -f "${file}" ]] || ! cmp -s "${tmp}" "${file}" 2>/dev/null; then
    mv "${tmp}" "${file}" 2>/dev/null || true
    log_verbose "[DIAG] autodecode ${id}: wrote ${file} (driver=${driver:-auto})"
    _set_preview_state "${id}" "pending"
    rm -f "${BASE}/.preview_attempts/${id}" 2>/dev/null || true
    if [[ "${reload}" == "true" ]]; then
      # Only the LISTEN instance reads these preview files — reload just it.
      # Touching RELOAD_FLAG/.reload_pipeline would needlessly restart the main
      # DECODE pipeline on every newly heard candidate (the churn seen in logs).
      # _request_listen_reload debounces bursts (many new candidates at once)
      # to at most one restart per 10 s, with a deferred fire for late arrivals.
      _request_listen_reload
    fi
  else
    rm -f "${tmp}" 2>/dev/null || true
    log_debug "[DIAG] autodecode ${id}: ${file} unchanged, no reload triggered"
  fi
}

sync_candidate_autodecode_files() {
  local id driver type_line rest
  [[ -f "${STATUS_CANDIDATES_FILE}" ]] || return 0
  while IFS=$'\t' read -r id driver type_line rest; do
    id="$(normalize_meter_id "${id}")"
    [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || continue
    ensure_candidate_autodecode "${id}" "${driver:-auto}" "${type_line:-}" "false"
  done < "${STATUS_CANDIDATES_FILE}"
}

# Remove meter-preview-<id> files for IDs that are now official configured meters.
# Called after sync_candidate_autodecode_files() to override any preview file it may
# have written for a candidate that was concurrently promoted to official status.
# Also removes the corresponding .preview_attempts/<id> counter.
# Does NOT touch status_candidate_values.tsv or status_candidate_preview_state.tsv.
prune_official_meter_previews() {
  local mid pf _pruned=0
  [[ -d "${METER_DIR}" ]] || return 0
  for mf in "${METER_DIR}"/meter-*; do
    [[ -f "${mf}" ]] || continue
    mid="$(grep -m1 '^id=' "${mf}" | cut -d= -f2 | tr '[:lower:]' '[:upper:]')"
    [[ "${mid}" =~ ^[0-9A-Fa-f]{8}$ ]] || continue
    pf="${LISTEN_METER_DIR}/meter-preview-${mid}"
    if [[ -f "${pf}" ]]; then
      rm -f "${pf}" 2>/dev/null || true
      rm -f "${BASE}/.preview_attempts/${mid}" 2>/dev/null || true
      log "pruned orphaned meter-preview-${mid} (now official configured meter)"
      _pruned=1
    fi
  done
  [[ "${_pruned}" -eq 1 ]] && _request_listen_reload
}

status_record_candidate_raw() {
  local id
  local raw="$2"
  local ts="${3:-}"
  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  [[ -n "${raw}" ]] || return 0
  [[ -n "${ts}" ]] || ts="$(iso_now)"

  _tsv_upsert "${STATUS_CANDIDATE_RAW_FILE}" "${id}" \
    "$(printf '%s\t%s\t%s\t%s' "${id}" "${ts}" "${#raw}" "${raw}")"
}

status_analyze_candidate_from_text() {
  local id
  local driver="${2:-auto}"
  local type_line="${3:-}"
  local type_lc raw_row raw_ts raw_len raw ci encryption note security

  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  type_lc="$(echo "${type_line}" | tr '[:upper:]' '[:lower:]')"

  raw_row="$(status_find_recent_raw_for_id "${id}" || true)"
  raw_ts=""
  raw_len="0"
  raw=""
  if [[ -n "${raw_row}" ]]; then
    IFS=$'\t' read -r raw_ts raw_len raw <<< "${raw_row}"
    status_record_candidate_raw "${id}" "${raw}" "${raw_ts}"
    # Best-effort CI position for normal wM-Bus DLL frames:
    # L(1), C(1), M(2), A/id+ver+type(6), CI(1) => byte offset 10 => hex offset 20.
    # This is metadata only. AES decision below does NOT rely on this guess.
    if [[ "${#raw}" -ge 22 ]]; then
      ci="${raw:20:2}"
    else
      ci=""
    fi
  else
    ci=""
  fi

  security=""

  # Do not guess encryption from driver. Only use explicit backend evidence:
  # 1) wmbusmeters/listen text explicitly says encrypted/AES,
  # 2) process_search_json marks a temporary no-key search meter as decoded.
  if candidate_type_requires_aes "${type_line}"; then
    encryption="aes_required"
    note="wmbusmeters/listen output explicitly reports encrypted/AES telegram"
  elif [[ -n "${raw}" ]]; then
    encryption="unknown"
    note="RAW was mapped to this candidate, but no backend security parser has classified AES yet"
  else
    encryption="unknown"
    note="No RAW/security analysis mapped to this candidate yet"
  fi

  status_upsert_candidate_analysis "${id}" "${encryption}" "${note}" "${ci}" "${security}" "${raw_len}" "$(iso_now)"
}

# shellcheck disable=SC2034
status_mark_search_decoded_no_aes() {
  local json_line="$1"
  local id meter media field
  id="$(normalize_meter_id "$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null || true)")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0

  # Search temporary meters are created without key=. If wmbusmeters decodes
  # numeric JSON from such a meter, then no AES key was required for that telegram.
  if is_search_temp_json "${json_line}"; then
    meter="$(jq -r '.meter // empty' <<<"${json_line}" 2>/dev/null || true)"
    media="$(jq -r '.media // empty' <<<"${json_line}" 2>/dev/null || true)"
    field="$(jq -r 'to_entries[] | select((.value|type)=="number") | .key' <<<"${json_line}" 2>/dev/null | head -n 1 || true)"
    status_upsert_candidate_analysis "${id}" "no_aes" "Temporary SEARCH meter decoded without key; no AES key was required for this telegram" "" "" "0" "$(iso_now)"
  fi
}

# Update the manufacturer column (9) of an EXISTING candidate row to the full
# text form captured by the LISTEN text path (e.g. "(NES) NORA ELK MALZ SAN ve TIC").
# Called from _process_listen_text_block BEFORE the driver guard so that
# manufacturer is recorded even when wmbusmeters omits the driver: line
# (e.g. for encrypted telegrams that can't be decrypted without the AES key).
# Only writes when column 9 is empty or holds a legacy bare 3-letter code;
# an existing full-text name is left untouched.
# Never creates rows, never touches reception stats or events.
candidate_update_manufacturer_text() {
  local _id="$1" _mfr="$2"
  [[ "${_id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  [[ -n "${_mfr}" ]] || return 0
  local _file="${STATUS_CANDIDATES_FILE}"
  [[ -f "${_file}" ]] || return 0
  # Cheap lock-free pre-check: only take the lock when a fillable row exists.
  awk -F '\t' -v id="${_id}" \
    '$1 == id && (NF < 9 || $9 == "" || ($9 ~ /^[A-Z]{3}$/)) { found = 1 } END { exit found ? 0 : 1 }' \
    "${_file}" 2>/dev/null || return 0
  (
    flock -x 9
    local _tmp
    _tmp="$(mktemp "${_file}.tmp.XXXXXX")" || return 1
    if ! awk -F $'\t' -v OFS=$'\t' -v id="${_id}" -v mfr="${_mfr}" '
        $1 == id {
          while (NF < 9) { $(NF + 1) = "" }
          if ($9 == "" || ($9 ~ /^[A-Z]{3}$/)) { $9 = mfr }
        }
        { print }
      ' "${_file}" > "${_tmp}"; then
      rm -f "${_tmp}"
      return 1
    fi
    if ! mv "${_tmp}" "${_file}"; then
      rm -f "${_tmp}"
      return 1
    fi
    log_debug "[DIAG] candidate ${_id}: updated manufacturer text from LISTEN block to ${_mfr}"
  ) 9>"${STATUS_CANDIDATES_FILE}.lock"
}

# shellcheck disable=SC2034
status_candidate_seen() {
  local id
  local driver="${2:-auto}"
  local type_line="${3:-}"
  local update_status="${4:-true}"
  local manufacturer="${5:-}"
  # reload controls whether a changed meter-preview-<id> file triggers an
  # immediate parallel LISTEN reload. Defaults to true for the text/RAW callers.
  # The decoded-JSON path (status_candidate_seen_from_json) passes false: a
  # candidate that just produced JSON is already decoding fine, so relabelling
  # its driver auto -> <real driver> must NOT kill+restart the LISTEN pipeline
  # on every telegram (reload churn that left previews stuck on "decoding...").
  local reload="${6:-true}"
  local now
  STATUS_WMBUSMETERS_RUNNING="true"
  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  local existed="false"
  if grep -q "^${id}	" "${STATUS_CANDIDATES_FILE}" 2>/dev/null; then
    existed="true"
  fi
  status_record_seen "${id}" "candidate"
  now="$(iso_now)"
  IFS=$'\t' read -r seen_count avg_interval_s seen_15m seen_60m < <(status_seen_stats "${id}" "candidate")
  _upsert_candidate_row "${id}" "${driver}" "${type_line}" "${now}" "${seen_count}" "${avg_interval_s}" "${seen_15m}" "${seen_60m}" "${manufacturer}"
  status_analyze_candidate_from_text "${id}" "${driver}" "${type_line}"
  ensure_candidate_autodecode "${id}" "${driver:-auto}" "${type_line:-}" "${reload}"
  if [[ "${existed}" != "true" ]]; then
    status_add_event "candidate" "Candidate detected ${id} (${driver})"
  fi
  [[ "${update_status}" == "true" ]] && write_status_json
}
