# Changelog

Development series `1.5.x-dev` of `wMBus MQTT Bridge Dev`.
Current `config.yaml` version: `1.5.11-dev.48`.

The development line ships incremental snapshots under
`ghcr.io/kustonium/{arch}-addon-wmbus_mqtt_bridge-dev`. Production
releases are tracked separately in the stable add-on repository.

Format: each entry is grouped into **Added** / **Changed** / **Fixed** /
**Runtime**. Most snapshots are single-commit; only items visible in
`config.yaml`, `bridge.sh`, `webui.py`, `i18n.py`, `app.js` or the SPA
assets are listed.

---

## 1.5.11-dev.48

### Changed

- Runtime tree synced from the upstream `homeassistant-wmbus-mqtt-bridge-newgui`
  repository at its `1.5.11-dev.47` commit. The dev add-on now ships the SPA
  WebGUI, the parallel LISTEN instance, soft pipeline reload, ESP detection from
  the RAW telegram topic, candidate preview values and the rewritten
  documentation set.
- Add-on identity preserved: `name`, `slug`, `description` prefix and
  `panel_title` continue to mark this build as the Dev channel.

### Runtime

- `rootfs/usr/share/wmbus-webui/` (SPA shell, `app.js`, `app.css`, `morphdom`)
  added.
- `LICENSE` and `THIRD_PARTY_NOTICES.md` added.

---

## 1.5.11-dev.47

### Changed

- HA pipeline tile reflects that decoded data lands in Home Assistant
  through the MQTT integration. Status text is one of `live via MQTT`,
  `ready`, `publishing…` or `idle` depending on `(discovery_ok,
  meter_count > 0)`. Sub-line shows the discovery prefix and meter
  count. Dot uses the standalone `.dot.ok` / `.dot.warn` / default CSS
  classes — no platform-dependent emoji.
- HA workspace drill-down explains that the bridge publishes MQTT
  Discovery and HA's MQTT integration picks the messages up, and lists
  Discovery prefix, state prefix and meter count.

### Cleanup

- `haStatusModel(model, meterCount)` helper shared between the pipeline
  tile and the workspace status row. Single source of truth for the
  four-state mapping.

---

## 1.5.11-dev.46

### Added

- Documentation rewritten for the Dev runtime.

---

## 1.5.11-dev.45

### Added

- Background MQTT subscriber on `RAW_TOPIC` writes per-device telegram
  stats to `status_esp_telegram_devices.tsv`. The segment matched by
  `+` in `raw_topic` is treated as the ESP device name; this is the
  primary source for ESP liveness detection and works without ESP-side
  diagnostic publishing.
- `_esp_payload()` in `webui.py` merges the telegram tracker with the
  legacy diag-events source. A device is active when either source has
  an entry in the last 5 minutes.
- ESP workspace gained `Telegrams` and `Diag` columns and now hides the
  "diagnostics required" notice when at least one ESP is publishing
  diag.

### Changed

- ESP pipeline node `N × ESP` badge counts only currently active
  devices.

---

## 1.5.11-dev.44

### Fixed

- ESP devices distinguish active from MQTT-retained "ghost" entries.
  Each `devices[]` entry now carries an `active` boolean; stale entries
  remain visible in the drill-down (greyed) but no longer inflate the
  pipeline badge.
- ESP workspace table sorts active devices first and shows a `N / M`
  count when stale entries exist.
- ESP Logs page renders a contextual notice covering ESP diagnostics
  configuration and the MQTT retained gotcha.

---

## 1.5.11-dev.43

### Fixed

- ESP Logs marks all currently active ESPs, not only the most recent
  one. The active detection aggregates the most recent summary epoch
  per device and treats every device with a summary in the last 5 min
  as active.

---

## 1.5.11-dev.42

### Added

- ESP pipeline node shows source topic and per-minute rate.
- ESP workspace drill-down lists all distinct ESP devices seen in
  events with topic and last-event metadata.
- Multi-ESP detection from event topics.

### Changed

- ESP diag/summary subscriber now records the source `_topic` alongside
  `_bridge_rx_epoch` in `status_esp_diag.json`.

---

## 1.5.11-dev.41

### Changed

- Dashboard pipeline tiles use real status dot colours, the ESP node
  shows the candidate count, and the wmbusmeters node shows the
  received/decoded ratio.
- Discover replaces the dashboard's redundant candidate panel; the
  pending meters panel was simplified.
- Navigation entry renamed `Discover` → `Received / Search` per
  language; nav code `DS` → `RX`.

---

## 1.5.11-dev.40

### Added

- Dashboard segmented view: `Pipeline` and `Statystyki` (statistics).
  Selection persists in `localStorage`.
- Statistics view: speed dial (current/previous minute, trend), source
  badge, session average, 15-minute sparkline, coverage funnel
  (in-air → configured → live).
- `bridge.sh` writes minute-boundary samples to
  `status_rate_history.tsv` (rolling 15 entries). `webui.py` exposes
  the series as `model.rate_history_15m`.

---

## 1.5.11-dev.39

### Fixed

- Preview value field selection prefers meaningful primary readings
  (`total_m3`, `current_power_consumption_kw`, …) over diagnostic
  counters that occasionally hold spurious large values
  (`backflow_m3`, fault counters, …).
- `status_candidate_values.tsv` is cleared on bridge startup so stale
  preview readings from previous sessions do not surface before the
  first new telegram arrives.

---

## 1.5.11-dev.38

### Removed

- Legacy server-rendered HTML renderer in `webui.py` (~1700 lines
  spanning `render_*` and `page_*` helpers, the legacy POST form
  handlers and the `/config` JSON helper). The SPA shell plus `/api/*`
  endpoints are the active interface.

---

## 1.5.11-dev.37

### Added

- Preview value action for candidates. POST `/api/preview-candidate`
  writes `meter-preview-<id>` to `listen/etc/wmbusmeters.d/` and
  touches `.reload_listen`; the parallel LISTEN instance reloads
  ~2-3 s later and decodes that ID without changing user-visible state.
- POST `/api/cancel-preview` removes the preview meter and clears the
  TSV row.

### Changed

- `parse_listen_candidates` in `bridge.sh` detects decoded JSON output
  and writes per-candidate primary readings to
  `status_candidate_values.tsv`.

---

## 1.5.11-dev.36

### Added

- Discover page shows decoded values for configured meters in the
  "Configured meters on air" panel.
- Client-side value filter (`value ± tolerance`) above the configured
  meters panel; filters by DOM `data-value` without re-rendering.

---

## 1.5.11-dev.35

### Added

- Logs page event legend and per-level colour styling
  (`ok` / `warn` / `error` / `candidate`).

---

## 1.5.11-dev.34

### Added

- Soft pipeline reload: `webui.py` touches `.reload_pipeline` and
  `bridge.sh` restarts only the DECODE pipeline (~5 s end-to-end)
  without restarting the container.
- Add-meter flow automatically calls `/api/reload-pipeline` after
  saving so the new meter starts decoding without manual restart.

### Changed

- `refresh_meter_files()` regenerates `wmbusmeters` meter files from
  `options.json` on every restart loop iteration so the new meter is
  picked up on the next decode start.
- Parallel LISTEN instance moves to a script-level start/stop pair so
  the candidate stream survives DECODE pipeline restarts.

---

## 1.5.11-dev.33

### Changed

- Discover page reflects the parallel-listen architecture: drops the
  "stale data" warnings, removes the `📡` indicators on the 15m/60m
  columns and adds the "Configured meters on air" panel.

---

## 1.5.11-dev.32

### Added

- Parallel LISTEN-only `wmbusmeters` instance when `meters` is
  non-empty. Uses a separate config dir under `/data/listen/etc/` so
  the LISTEN instance always runs in listen mode regardless of the
  primary DECODE configuration.

---

## 1.5.11-dev.31

### Added

- Ports remaining legacy behaviours into the SPA: age-adjusted
  `seen_15m` / `seen_60m` based on `last_seen` for meters and
  candidates, encryption hint badge text aligned with the bridge's
  classification, event-level colouring and `Candidate detected`
  re-labelling for `Detected unconfigured meter` warnings,
  `fmtInterval` rounding rules.

---

## 1.5.11-dev.30

### Fixed

- `pending_restart` detection compares `options.json` mtime against
  `status_bridge_start.txt` (written once at bridge startup) instead of
  the constantly-updated `status.json`. The pending-restart banner no
  longer disappears within seconds of a meter being added.

---

## 1.5.11-dev.29

### Changed

- Merged the dashboard pending-restart banner and waiting-for-telegram
  panel into a single panel that shows the meters list, the restart
  button (visible only while restart is actually pending), and the
  appropriate header.

---

## 1.5.11-dev.28

### Added

- Pending meters table below the configured meters panel on the
  dashboard (entries in `options.json` not yet decoded).

---

## 1.5.11-dev.27

### Added

- Restart overlay: clicking `Restart add-on` shows a full-page
  `🔄 Restarting add-on…` overlay and polls `/api/status` every 3 s
  for up to 90 s. The HTTP 502 returned while the add-on is restarting
  no longer surfaces as a user error.

### Changed

- SSE stream is closed when entering the restart overlay so the browser
  does not log a network error.

---

## 1.5.11-dev.26

### Fixed

- `pendingRestartBanner` falls back to comparing the pending-meter
  count (entries in `options.json` not yet decoded) when the mtime
  signal is unreliable.

---

## 1.5.11-dev.25

### Changed

- ESP Logs page reduced to "Suggestion" and "ESP events" sections; the
  Diagnostics/Boot panels were removed.
- ESP Logs identifies the active ESP device from the most recent
  summary topic and surfaces it in the section header.

---

## 1.5.11-dev.24

### Changed

- Candidate panel is hidden from the dashboard when configured meters
  exist; the dashboard meters/pending sections expand to full width.

---

## 1.5.11-dev.23

### Added

- Media icons in the meters table.
- More complete i18n coverage across the SPA strings.

### Removed

- Redundant `Refresh` and `Legacy UI` navigation buttons.

---

## 1.5.11-dev.22

### Fixed

- RAW rate in DECODE mode reads only `status_meters.tsv` to avoid
  inflated values from a stale `status_candidates.tsv` left over from
  a previous LISTEN session.
- Decode-mode candidate notice text describes the actual cause (data
  from previous LISTEN session) rather than a misleading "raw MQTT
  signal" message.

---

## 1.5.11-dev.21

### Added

- Decode-mode notice in the candidates table explaining that
  `status_candidates.tsv` is not updated while DECODE is the active
  mode.

---

## 1.5.11-dev.20

### Fixed

- `raw_per_min` uses the ESP's `total` field when an ESP diagnostic
  summary is fresh (within 150 s of `_bridge_rx_epoch`); avoids
  divide-by-short-elapsed inflation at startup.

---

## 1.5.11-dev.19

### Fixed

- Statistics chart bars use separate scales for candidate/meter counts
  and per-minute rate so neither bar collapses to invisible.

---

## 1.5.11-dev.18 and earlier

Earlier dev snapshots (`1.5.11-dev.0` – `1.5.11-dev.17`) introduced the
SPA scaffold, the pending banners, the meters table actions, and the
initial dashboard layout. Detailed commit messages remain available in
`git log --grep '^ci(dev)' --invert-grep --since='2026-04-01'`.

---

## 1.5.3-dev

### Added

- Field-suffix unit detection in `bridge.sh` and the WebGUI covers
  `_kvarh`, `_kvah`, `_m3h`, `_mjh`, `_kvar`, `_kva`, `_kwh`, `_kw`,
  `_wh`, `_w`, `_lh`, `_jh`, `_gj`, `_mj`, `_dbm`, `_hca`, `_pct`,
  `_ppm`, `_rh`, `_hz`, `_bar`, `_pa`, `_m3`, `_mol`, `_min`, `_rad`,
  `_deg`, `_counter`, `_factor`, `_nr`, `_kg`, `_cd`, `_v`, `_a`,
  `_k`, `_c`, `_f`, `_l`, `_m`, `_s`, `_h`, `_d`, `_y`. Longer
  suffixes are checked before shorter ones to avoid false matches.
- Dynamic meter status label (`online` / `silent` / `offline`) based
  on the recent reception counters.
- Restart button restored in the pending-meters panel.

### Changed

- Discovery templates use defensive
  `value_json.get(...) | default(none)`.
- `expire_after` is derived from the observed average interval when
  available.
- `state_class: measurement` is limited to device classes where it
  applies.
- `device_class` for `m3` is derived from the reported meter media
  when possible.

### CI

- Build workflow path filters narrowed so doc-only commits do not
  rebuild images.
- `sync-rootfs` workflow keeps the stable add-on runtime tree aligned
  with the dev tree.

### Notes

- Versions `1.5.1-dev` and `1.5.2-dev` were not published as separate
  dev snapshots; incremental fixes from those numbers were promoted
  straight to the stable channel.

---

## 1.5.0-dev

First development snapshot of the embedded WebGUI work.

### Added

- WebGUI served through Home Assistant Ingress on port `8099`.
- Python HTTP/API service in `rootfs/usr/bin/webui.py`.
- s6 WebGUI service in `rootfs/etc/services.d/wmbus_webui/run`.
- Multilingual translation layer in `rootfs/usr/bin/i18n.py`
  (`en`, `pl`, `de`, `cs`, `sk`).
- Per-language documentation under `docs/`.

### Changed

- Add-on stage set to `experimental`.
- Default Home Assistant `search_tolerance_m3` set to `0.05`.
- `bridge.sh` extended to write the runtime status, candidate data and
  control flags required by the WebGUI.
- Dockerfile add-on stage adds Python for the WebGUI.

### Notes

- `1.5.0-dev` followed the `1.4.x` line and opened the Dev series.
