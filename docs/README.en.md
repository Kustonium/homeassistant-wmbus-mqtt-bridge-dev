> [EN](README.en.md) | [PL](README.pl.md) | [DE](README.de.md) | [CS](README.cs.md) | [SK](README.sk.md)

# wMBus MQTT Bridge Dev - documentation EN

Version described here: `1.5.11-dev.45`.

This document replaces the old WebGUI documentation. It was rewritten from the
current code logic in `bridge.sh`, `webui.py`, `app.js`, `config.yaml`, `run.sh`
and `docker/entrypoint.sh`.

The old documentation set was maintained in five languages, and the same layout
is kept:

- `docs/README.pl.md` - Polish
- `docs/README.en.md` - English
- `docs/README.de.md` - German
- `docs/README.cs.md` - Czech
- `docs/README.sk.md` - Slovak

Translations are machine-generated and may contain mistakes in PL and EN too.

## 1. What the add-on does

The add-on decodes Wireless M-Bus telegrams without a local radio receiver
attached to Home Assistant. Raw HEX frames arrive through MQTT, and the add-on
feeds them into `wmbusmeters` through `stdin:hex`.

Typical pipeline:

```text
ESP32 / gateway / bridge
  -> MQTT raw HEX: wmbus/+/telegram
  -> bridge.sh
  -> wmbusmeters --useconfig /data
  -> MQTT state: wmbusmeters/<id>/...
  -> Home Assistant MQTT Discovery: homeassistant/...
```

The project does not replace the `wmbusmeters` decoder. It provides MQTT input,
configuration, runtime state, Home Assistant Discovery and the WebGUI.

## 2. Main components

| Component | File | Role |
|---|---|---|
| `bridge.sh` | `rootfs/usr/bin/bridge.sh` | Subscribes to RAW MQTT, runs `wmbusmeters`, publishes MQTT/Discovery and writes runtime status. |
| `webui.py` | `rootfs/usr/bin/webui.py` | HTTP/API server on port `8099`, Ingress handling, API, SSE and WebGUI actions. |
| SPA WebGUI | `rootfs/usr/share/wmbus-webui/` | Static frontend: `index.html`, `app.js`, `app.css`, `morphdom.min.js`. |
| HA start | `rootfs/usr/bin/run.sh` | Selects MQTT broker in `auto`, `ha` or `external` mode. |
| Docker start | `docker/entrypoint.sh` | Creates `/config/options.json`, starts `webui.py` and `bridge.sh`. |

## 3. Bridge modes

### LISTEN

When `meters` is empty, the add-on listens to all telegrams and writes
candidates to `status_candidates.tsv`. This is the first-start mode.

### DECODE

When `meters` contains at least one meter, `bridge.sh` generates `wmbusmeters`
config files under `/data/etc/wmbusmeters.d/`, decodes matching IDs and
publishes results to MQTT and Home Assistant Discovery.

### DECODE + parallel LISTEN

After meters are configured, a parallel LISTEN instance also runs. The WebGUI
can still see candidates in the air while the main pipeline decodes configured
meters.

### SEARCH

SEARCH still exists in the backend and in the hidden `#/search` route. It
compares a physical meter reading against decoded candidates. In the new WebGUI,
the main identification flow is `#/discover`: preview value, value filtering and
adding directly from the table.

## 4. Dev WebUI

The new WebGUI is a static SPA. `webui.py` serves files from
`/usr/share/wmbus-webui` and exposes data through API endpoints.

Important endpoints:

| Endpoint | Method | Meaning |
|---|---:|---|
| `/api/app` | GET | Full SPA data model, including i18n. |
| `/api/events` | GET | Server-Sent Events for live refresh. |
| `/api/status` | GET | Raw `state()` snapshot. |
| `/api/add-meter` | POST | Add a meter to `options.json`. |
| `/api/remove-meter` | POST | Remove a meter from `options.json`. |
| `/api/reload-pipeline` | POST | Touch `.reload_pipeline`, soft-restart the DECODE pipeline. |
| `/api/preview-candidate` | POST | Create a temporary meter-preview in LISTEN. |
| `/api/cancel-preview` | POST | Remove preview and reload LISTEN. |
| `/api/ignore`, `/api/unignore` | POST | Hide/restore candidates. |
| `/api/restart-bridge` | POST | Restart the add-on through Supervisor when running under HA. |
| `/api/search-control` | POST | Advanced SEARCH control. |

### Live refresh

The frontend opens an `EventSource` connection to `/api/events`. The backend
sends a new payload when state changes and also sends heartbeat comments.
Rendering is patched by `morphdom`, so the screen should not flicker or lose
focus in an active field. If `EventSource` is unavailable, the frontend falls
back to polling.

### Views

| Route | Description |
|---|---|
| `#/dashboard` | Default page. Switch between pipeline and statistics. |
| `#/meters` | Configured meters, pending meters, removal. |
| `#/discover` | Candidates, preview value, add, ignore, media/value filters. |
| `#/logs` | Runtime events written by bridge/WebUI. |
| `#/esp-logs` | ESP diagnostics, events, suggestions and boot info. |
| `#/settings` | Current configuration, runtime and pipeline snapshot. |
| `#/about` | Version, runtime mode and paths. |
| `#/search` | Advanced hidden SEARCH view. |

### Dashboard

The dashboard has two modes, persisted in `localStorage`:

- `pipeline` - four nodes: ESP, MQTT, wMBus, Home Assistant. Clicking a node
  opens a detail workspace.
- `stats` - old statistics logic moved into the new UI: current minute,
  previous minute, trend, candidates, configured meters, telegrams/min,
  sparkline and coverage/funnel.

## 5. Languages

The WebGUI uses dictionaries from `rootfs/usr/bin/i18n.py`.

Supported languages:

- `en` - English
- `pl` - Polski
- `de` - Deutsch
- `cs` - Česky
- `sk` - Slovenčina

Language detection order:

1. `?lang=` parameter
2. `wmbus_lang` cookie
3. `Accept-Language` header
4. default `en`

The frontend has no separate translation files. It receives the dictionary from
`/api/app`, and local aliases in `app.js` map new UI labels to existing keys
where possible.

## 6. Home Assistant

The add-on is described in `config.yaml` as experimental Dev:

- `name: wMBus MQTT Bridge Dev`
- `slug: wmbus_mqtt_bridge_dev`
- `ingress: true`
- `ingress_port: 8099`
- `hassio_api: true`
- `panel_title: wMBus Bridge Dev`

MQTT options:

| Option | Meaning |
|---|---|
| `mqtt_mode: auto` | Use HA broker when available; otherwise external settings. |
| `mqtt_mode: ha` | Force the Home Assistant broker. |
| `mqtt_mode: external` | Use `external_mqtt_*` settings. |

The default HA RAW topic is `wmbus/+/telegram`.

## 7. Docker standalone

Docker runs without Supervisor API. `docker/entrypoint.sh`:

1. sets `WMBUS_BASE`, default `/config`,
2. creates `/config/options.json` if missing,
3. reads `external_mqtt_*` from it,
4. exports `MQTT_HOST`, `MQTT_PORT`, `MQTT_USER`, `MQTT_PASS`,
5. starts the WebGUI on `WEBUI_PORT`, default `8099`,
6. runs `bridge.sh`.

Under Docker, `/config` must be writable. The WebGUI and bridge write status,
configuration and `wmbusmeters` files there.

Example:

```yaml
services:
  wmbus:
    build:
      context: .
      dockerfile: Dockerfile
      target: addon
    entrypoint: ["/usr/bin/docker-entrypoint.sh"]
    ports:
      - "8099:8099"
    volumes:
      - ./config:/config
    environment:
      WMBUS_BASE: /config
      WEBUI_PORT: 8099
```

## 8. Main options

| Option | Default | Description |
|---|---:|---|
| `raw_topic` | `wmbus/+/telegram` in HA | Topic carrying raw HEX. Docker's generated default file may use `wmbus_bridge/+/telegram`. |
| `loglevel` | `normal` | `normal`, `verbose`, `debug`. |
| `filter_hex_only` | `true` | Reject payloads that do not look like HEX. |
| `discovery_enabled` | `true` | Publish MQTT Discovery for HA. |
| `discovery_prefix` | `homeassistant` | Discovery prefix. |
| `state_prefix` | `wmbusmeters` | MQTT state prefix. |
| `state_retain` | `false` | Retain state messages. |
| `meters` | `[]` | Configured meters list. |
| `search_mode` | `false` | Advanced reading-based matching. |
| `search_expected_value_m3` | `0` | Expected meter reading in m3. |
| `search_tolerance_m3` | `0.05` | SEARCH tolerance. |

Meter entry:

```json
{
  "id": "cold_water_bathroom",
  "meter_id": "41553221",
  "type": "mkradio3",
  "type_other": "",
  "key": ""
}
```

`meter_id` must be an 8-character ID. Leave `key` empty for unencrypted meters,
or enter a 32-character HEX AES key.

## 9. Runtime files

| File | Written by | Read by | Meaning |
|---|---|---|---|
| `options.json` | HA/Docker/WebGUI | `bridge.sh`, `webui.py` | User configuration. |
| `status.json` | `bridge.sh` | `webui.py` | MQTT, pipeline and config status. |
| `status_meters.tsv` | `bridge.sh` | `webui.py` | Configured meters after decode. |
| `status_candidates.tsv` | `bridge.sh` | `webui.py` | LISTEN candidates. |
| `status_events.tsv` | `bridge.sh`, `webui.py` | `webui.py` | Runtime events. |
| `status_seen.tsv` | `bridge.sh` | `bridge.sh` | Per-ID visibility stats. |
| `status_rate_1m.json` | `bridge.sh` | `webui.py` | Current and previous minute. |
| `status_rate_history.tsv` | `bridge.sh` | `webui.py` | 15-minute chart history. |
| `status_candidate_analysis.tsv` | `bridge.sh` | `webui.py` | Candidate encryption analysis. |
| `status_candidate_values.tsv` | `bridge.sh` | `webui.py` | Candidate preview values. |
| `status_esp_telegram_devices.tsv` | `bridge.sh` | `webui.py` | Active ESPs detected from RAW topic. |
| `status_esp_events.tsv` | `bridge.sh` | `webui.py` | ESP diag events. |
| `status_esp_diag.json` | `bridge.sh` | `webui.py` | Latest ESP summary. |
| `.reload_pipeline` | `webui.py` | `bridge.sh` | Soft restart of DECODE pipeline. |
| `.reload_listen` | `webui.py` | `bridge.sh` | Restart parallel LISTEN. |

## 10. ESP diagnostics

Active ESPs are detected from two sources:

1. `status_esp_telegram_devices.tsv` - primary source. `bridge.sh` listens to
   `RAW_TOPIC`; the segment matching `+` is the device name, for example
   `wmbus/xiaoseed/telegram`.
2. `status_esp_events.tsv` and `status_esp_diag.json` - secondary source from
   `wmbus/+/diag/...`.

A device is active if it had a RAW telegram or diag summary in the last 5
minutes. This prevents old MQTT retained messages from pretending that an ESP is
still alive.

## 11. License

The project is distributed under GNU GPL v3.0. The full text is in `../LICENSE`.

Upstream:

- `wmbusmeters` - GPL-3.0
- `wmbusmeters-ha-addon` - GPL-3.0

Dev is inspired by the Zigbee2MQTT workflow: separate frontend, API and live
updates. The current comparison with local `zigbee2mqtt-master` does not show
copied Zigbee2MQTT code or assets in this repository. If real Z2M code/assets
are added later, copyright notices, license text and modification notices must
be preserved under GPL-3.0.

`morphdom.min.js` is bundled under the MIT license. Details are in
`../THIRD_PARTY_NOTICES.md`.
