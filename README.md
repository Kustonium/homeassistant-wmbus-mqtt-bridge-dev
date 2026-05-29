# wMBus MQTT Bridge Dev

[![EN](https://img.shields.io/badge/lang-EN-blue)](#english)
[![PL](https://img.shields.io/badge/lang-PL-red)](#polski)
[![DE](https://img.shields.io/badge/lang-DE-yellow)](#deutsch)
[![CS](https://img.shields.io/badge/lang-CS-green)](#česky)
[![SK](https://img.shields.io/badge/lang-SK-orange)](#slovenčina)

Home Assistant add-on (and standalone Docker image) that decodes Wireless
M-Bus telegrams without a local radio dongle. Raw HEX frames arrive over
MQTT from an external receiver (typically an ESP32 with CC1101 / SX1276 /
SX1262); the add-on feeds them into upstream `wmbusmeters`, publishes
decoded JSON to MQTT, and emits Home Assistant MQTT Discovery messages.

Add-on slug: `wmbus_mqtt_bridge_dev`
Stage: `experimental` (1.5.x-dev series)
Architectures: `amd64`, `aarch64`

Per-language reference docs in [`docs/README.{en,pl,de,cs,sk}.md`](docs/).
Onboarding in [`docs/GETTING_STARTED.md`](docs/GETTING_STARTED.md).

---

## English

### Pipeline

```
ESP receiver → MQTT raw HEX (wmbus/<device>/telegram by default)
            → bridge.sh (mosquitto_sub | awk hex filter | wmbusmeters)
            → MQTT state (wmbusmeters/<id>/state)
            → MQTT Discovery (homeassistant/…)
            → Home Assistant MQTT integration
```

The add-on does not reimplement the decoder. Upstream `wmbusmeters`
handles parsing and field extraction. This project provides MQTT plumbing,
configuration management, runtime status, Home Assistant Discovery and the
WebGUI.

### Components

| Component | Path | Role |
|---|---|---|
| Pipeline driver | `rootfs/usr/bin/bridge.sh` | Subscribes to RAW MQTT, runs `wmbusmeters`, publishes decoded JSON + Discovery, writes runtime status files. |
| HTTP/API server | `rootfs/usr/bin/webui.py` | Serves the SPA, exposes `/api/*` endpoints, streams Server-Sent Events. |
| i18n catalogue | `rootfs/usr/bin/i18n.py` | Translation dictionary for `en`, `pl`, `de`, `cs`, `sk`. |
| SPA frontend | `rootfs/usr/share/wmbus-webui/` | `index.html`, `assets/app.js`, `assets/app.css`, `assets/morphdom.min.js`. |
| HA service runner | `rootfs/usr/bin/run.sh` | Picks the MQTT broker according to `mqtt_mode`. |
| Docker entry | `docker/entrypoint.sh` | Creates `/config/options.json` on first run, then launches both services. |

### Modes

| Mode | Trigger | Behaviour |
|---|---|---|
| LISTEN | `meters: []` | Single `wmbusmeters` instance reports every observed ID into `status_candidates.tsv`. |
| DECODE | `meters` non-empty | Generated `meter-NNNN` files under `/data/etc/wmbusmeters.d/` drive a decoding instance. Decoded JSON publishes to MQTT state and Discovery. |
| DECODE + parallel LISTEN | DECODE active | A second `wmbusmeters` instance under `/data/listen/etc/wmbusmeters.d/` runs in pure listen mode so candidate visibility is preserved. |
| SEARCH | `search_mode: true`, `search_expected_value_m3 > 0` | Compares decoded readings against an expected m³ value. Backend logic; the hidden `#/search` route still exposes its status. |

### WebGUI routes

| Route | Purpose |
|---|---|
| `#/dashboard` | Pipeline tiles (ESP / MQTT / wmbusmeters / HA) or statistics view (current/previous minute, trend, 15-minute sparkline, coverage funnel). Selection persisted in `localStorage`. |
| `#/meters` | Configured meters table and pending entries (in `options.json` but not yet decoded). |
| `#/discover` | LISTEN candidates with reception stats, encryption analysis, preview value, value filter, add and ignore actions. Hosts the “Configured meters on air” panel. |
| `#/logs` | Runtime event stream with colour-coded levels and the raw/candidate legend. |
| `#/esp-logs` | ESP device events, active-device badges, latest diagnostic summary, last suggestion. |
| `#/settings` | Active configuration and runtime snapshot. |
| `#/about` | Version, runtime mode, paths. |
| `#/search` | Hidden advanced SEARCH workspace; reachable by direct hash. |

### Home Assistant configuration

`config.yaml` declares:

- `ingress: true`, `ingress_port: 8099`
- `hassio_api: true`
- `panel_title: wMBus Bridge Dev`
- `services: [mqtt:want]`
- Default `raw_topic: wmbus/+/telegram`

MQTT modes:

| `mqtt_mode` | Effect |
|---|---|
| `auto` | Use the Home Assistant broker when available; fall back to `external_mqtt_*` otherwise. |
| `ha` | Force the HA broker. |
| `external` | Use `external_mqtt_host`, `external_mqtt_port`, `external_mqtt_username`, `external_mqtt_password`. |

### Docker standalone

`docker/entrypoint.sh` writes `/config/options.json` on first run, exports
MQTT settings from it, starts the WebGUI on `WEBUI_PORT` (default `8099`),
then exec’s `bridge.sh`. `/config` must be writable.

```yaml
services:
  wmbus:
    build:
      context: .
      dockerfile: Dockerfile
      target: addon
    entrypoint: ["/usr/bin/docker-entrypoint.sh"]
    ports: ["8099:8099"]
    volumes: ["./config:/config"]
    environment:
      WMBUS_BASE: /config
      WEBUI_PORT: 8099
```

### Configuration options

| Option | Default | Notes |
|---|---|---|
| `raw_topic` | `wmbus/+/telegram` | MQTT topic for raw HEX payloads. The `+` segment is used as the ESP device name. |
| `loglevel` | `normal` | `normal`, `verbose`, `debug`. |
| `filter_hex_only` | `true` | Drop non-HEX and odd-length payloads. |
| `debug_every_n` | `0` | If >0, log every N-th hex line to stderr. |
| `discovery_enabled` | `true` | Publish HA MQTT Discovery. |
| `discovery_prefix` | `homeassistant` | Discovery topic prefix. |
| `discovery_retain` | `true` | Retain Discovery configs. |
| `state_prefix` | `wmbusmeters` | Prefix for decoded state topics. |
| `state_retain` | `false` | Retain decoded state messages. |
| `search_mode` | `false` | Enable SEARCH workflow. |
| `search_expected_value_m3` | `0` | SEARCH target reading. |
| `search_tolerance_m3` | `0.05` | SEARCH match tolerance. |
| `search_delta_mode` | `false` | Match by delta from first observation. |
| `search_min_delta_m3` | `0.001` | Minimum delta for `search_delta_mode`. |
| `search_topic` | `wmbus/search/candidates` | Topic SEARCH writes match payloads to. |
| `meters` | `[]` | Configured meters list (see below). |
| `mqtt_mode` | `auto` | `auto`, `ha`, `external`. |
| `external_mqtt_host/port/username/password` | empty | External broker (used in `external` and `auto` fallback). |

Meter entry:

```json
{
  "id": "cold_water_kitchen",
  "meter_id": "12345678",
  "type": "mkradio3",
  "type_other": "",
  "key": ""
}
```

- `id` — stable identifier used in generated `wmbusmeters` configs and HA entity IDs.
- `meter_id` — 8-character hex ID printed on the meter.
- `type` — a `wmbusmeters` driver name, or `auto`, or `other`.
- `type_other` — driver name when `type: other`.
- `key` — empty for unencrypted meters, 32 hex characters for AES.

### Runtime files

HA base: `/data`. Docker base: `/config`.

| File | Writer | Reader | Content |
|---|---|---|---|
| `options.json` | HA / Docker / WebGUI | bridge.sh, webui.py | User configuration. |
| `status.json` | bridge.sh | webui.py | MQTT / pipeline / config status. |
| `status_meters.tsv` | bridge.sh | webui.py | Last decoded values per configured meter. |
| `status_candidates.tsv` | bridge.sh | webui.py | LISTEN candidates. |
| `status_candidate_analysis.tsv` | bridge.sh | webui.py | Per-candidate AES classification. |
| `status_candidate_values.tsv` | bridge.sh (LISTEN preview) | webui.py | Per-candidate preview readings. |
| `status_events.tsv` | bridge.sh, webui.py | webui.py | Runtime events. |
| `status_seen.tsv` | bridge.sh | bridge.sh | Per-ID visibility counters. |
| `status_rate_1m.json` | bridge.sh | webui.py | Current and previous minute rates. |
| `status_rate_history.tsv` | bridge.sh | webui.py | 15-row rolling chart history. |
| `status_recent_raw.tsv` | bridge.sh | bridge.sh | Recent RAW frames. |
| `status_esp_telegram_devices.tsv` | bridge.sh | webui.py | Active ESPs from RAW topic. |
| `status_esp_events.tsv` | bridge.sh | webui.py | ESP diag events. |
| `status_esp_diag.json` | bridge.sh | webui.py | Latest ESP summary. |
| `status_esp_suggestion.json` | bridge.sh | webui.py | Latest ESP suggestion. |
| `status_esp_boot.json` | bridge.sh | webui.py | Latest ESP boot record. |
| `status_bridge_start.txt` | bridge.sh | webui.py | Start epoch (used for `pending_restart` detection). |
| `.reload_pipeline` | webui.py | bridge.sh | Soft-restart the DECODE pipeline. |
| `.reload_listen` | webui.py | bridge.sh | Soft-restart the parallel LISTEN instance. |
| `search_candidates.tsv`, `search_matches.tsv`, `search_status.json` | bridge.sh | webui.py | SEARCH state. |

### API endpoints

`webui.py` serves the SPA shell plus `/api/*`. The legacy server-rendered HTML
routes were removed in 1.5.11-dev.39.

| Endpoint | Method | Notes |
|---|---|---|
| `/api/app` | GET | Frontend payload (state + i18n dictionary). |
| `/api/events` | GET | Server-Sent Events stream for live refresh. |
| `/api/status` | GET | Raw `state()` snapshot. |
| `/api/add-meter` | POST | Add an entry to `options.json`. |
| `/api/remove-meter` | POST | Remove an entry from `options.json`. |
| `/api/preview-candidate` | POST | Write `meter-preview-<id>` to LISTEN config and touch `.reload_listen`. |
| `/api/cancel-preview` | POST | Remove preview and touch `.reload_listen`. |
| `/api/reload-pipeline` | POST | Touch `.reload_pipeline`. bridge.sh kills the DECODE pipeline; the restart loop refreshes meter files and respawns. |
| `/api/ignore`, `/api/unignore` | POST | Hide / restore a candidate. |
| `/api/restart-bridge` | POST | Restart the add-on through the Supervisor API (HA only). |
| `/api/search-control` | POST | Advanced SEARCH control. |
| `/healthz` | GET | Liveness probe. |

### ESP device detection

Two sources, merged in `_esp_payload()`:

1. **Primary** — `status_esp_telegram_devices.tsv`. A background subscriber on `RAW_TOPIC` extracts the segment matching the `+` wildcard and updates a per-device row (last-seen, telegram count). Telegrams are not retained, so dead ESPs age out within the active window.
2. **Secondary** — `status_esp_events.tsv` and `status_esp_diag.json`. Filled by separate subscribers on `wmbus/+/diag` and `wmbus/+/diag/#`.

A device is **active** when either source has an entry in the last 5 minutes.
Stale entries (typically MQTT-retained boot messages from devices that are
no longer publishing) stay listed in the workspace drill-down but do not
count in the pipeline ESP badge.

### Languages

| Code | Name |
|---|---|
| `en` | English |
| `pl` | Polski |
| `de` | Deutsch |
| `cs` | Česky |
| `sk` | Slovenčina |

Selection order: `?lang=` → `wmbus_lang` cookie → `Accept-Language` → `en`.

### Licence

GNU GPL v3.0 ([`LICENSE`](LICENSE)).

Upstream code under the same licence:
- `wmbusmeters` — <https://github.com/wmbusmeters/wmbusmeters>
- `wmbusmeters-ha-addon` — <https://github.com/wmbusmeters/wmbusmeters-ha-addon>

Third-party bundled assets in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md):
- `assets/morphdom.min.js` — MIT.

---

## Polski

### Pipeline

```
Odbiornik ESP → MQTT RAW HEX (domyślnie wmbus/<device>/telegram)
             → bridge.sh (mosquitto_sub | awk hex filter | wmbusmeters)
             → MQTT state (wmbusmeters/<id>/state)
             → MQTT Discovery (homeassistant/…)
             → integracja MQTT w Home Assistant
```

Add-on nie reimplementuje dekodera. Parsowanie i ekstrakcję pól robi upstream
`wmbusmeters`. Ten projekt dostarcza warstwę MQTT, zarządzanie konfiguracją,
status runtime, Home Assistant Discovery oraz WebGUI.

### Komponenty

| Komponent | Ścieżka | Rola |
|---|---|---|
| Driver pipeline | `rootfs/usr/bin/bridge.sh` | Subskrybuje RAW MQTT, uruchamia `wmbusmeters`, publikuje JSON i Discovery, zapisuje status runtime. |
| Serwer HTTP/API | `rootfs/usr/bin/webui.py` | Serwuje SPA, eksponuje `/api/*`, streamuje SSE. |
| Katalog i18n | `rootfs/usr/bin/i18n.py` | Słownik tłumaczeń `en`, `pl`, `de`, `cs`, `sk`. |
| Frontend SPA | `rootfs/usr/share/wmbus-webui/` | `index.html`, `assets/app.js`, `assets/app.css`, `assets/morphdom.min.js`. |
| Runner HA | `rootfs/usr/bin/run.sh` | Wybiera brokera MQTT na podstawie `mqtt_mode`. |
| Entry Docker | `docker/entrypoint.sh` | Tworzy `/config/options.json` przy pierwszym starcie i uruchamia oba serwisy. |

### Tryby

| Tryb | Warunek | Zachowanie |
|---|---|---|
| LISTEN | `meters: []` | Jedna instancja `wmbusmeters` raportuje każde ID do `status_candidates.tsv`. |
| DECODE | `meters` niepusta | Wygenerowane pliki `meter-NNNN` w `/data/etc/wmbusmeters.d/` napędzają instancję dekodującą. JSON publikowany na MQTT state + Discovery. |
| DECODE + równoległy LISTEN | DECODE aktywny | Druga instancja `wmbusmeters` w `/data/listen/etc/wmbusmeters.d/` (zawsze pusta) działa w trybie listen, żeby zachować widoczność kandydatów. |
| SEARCH | `search_mode: true`, `search_expected_value_m3 > 0` | Porównuje dekodowane wartości z oczekiwanym stanem licznika. Logika backendowa; ukryta trasa `#/search`. |

### Trasy WebGUI

| Trasa | Cel |
|---|---|
| `#/dashboard` | Kafelki pipeline (ESP / MQTT / wmbusmeters / HA) lub widok statystyk (bieżąca/poprzednia minuta, trend, sparkline 15 minut, lejek pokrycia). Wybór zapisywany w `localStorage`. |
| `#/meters` | Tabela skonfigurowanych liczników i wpisy pending (zapisane w `options.json`, jeszcze nie zdekodowane). |
| `#/discover` | Kandydaci LISTEN ze statystykami odbioru, analizą szyfrowania, preview wartości, filtrem po wartości, dodawaniem i ignorowaniem. Mieści panel „Skonfigurowane liczniki w eterze”. |
| `#/logs` | Strumień zdarzeń runtime z kolorami poziomów i legendą raw/kandydat. |
| `#/esp-logs` | Zdarzenia ESP, badge aktywnych urządzeń, ostatnie podsumowanie diagnostyczne, ostatnia sugestia. |
| `#/settings` | Aktywna konfiguracja i snapshot runtime. |
| `#/about` | Wersja, tryb runtime, ścieżki. |
| `#/search` | Ukryta zaawansowana sekcja SEARCH; dostępna przez bezpośredni hash. |

### Konfiguracja Home Assistant

`config.yaml` deklaruje:

- `ingress: true`, `ingress_port: 8099`
- `hassio_api: true`
- `panel_title: wMBus Bridge Dev`
- `services: [mqtt:want]`
- Domyślny `raw_topic: wmbus/+/telegram`

Tryby MQTT:

| `mqtt_mode` | Efekt |
|---|---|
| `auto` | Użyj brokera HA gdy dostępny; fallback do `external_mqtt_*`. |
| `ha` | Wymuś brokera HA. |
| `external` | Użyj `external_mqtt_host`, `external_mqtt_port`, `external_mqtt_username`, `external_mqtt_password`. |

### Docker standalone

`docker/entrypoint.sh` przy pierwszym starcie zapisuje `/config/options.json`,
eksportuje z niego ustawienia MQTT, uruchamia WebGUI na `WEBUI_PORT`
(domyślnie `8099`), następnie `exec`-uje `bridge.sh`. `/config` musi być
zapisywalny.

### Opcje konfiguracji

| Opcja | Domyślnie | Uwagi |
|---|---|---|
| `raw_topic` | `wmbus/+/telegram` | Topic MQTT z RAW HEX. Segment `+` to nazwa urządzenia ESP. |
| `loglevel` | `normal` | `normal`, `verbose`, `debug`. |
| `filter_hex_only` | `true` | Odrzuca payload nie-HEX i o nieparzystej długości. |
| `debug_every_n` | `0` | Jeśli >0, loguje co N-tą linię HEX na stderr. |
| `discovery_enabled` | `true` | Publikuje HA MQTT Discovery. |
| `discovery_prefix` | `homeassistant` | Prefix Discovery. |
| `discovery_retain` | `true` | Retain configów Discovery. |
| `state_prefix` | `wmbusmeters` | Prefix topiców state. |
| `state_retain` | `false` | Retain wiadomości state. |
| `search_mode` | `false` | Włącza workflow SEARCH. |
| `search_expected_value_m3` | `0` | Oczekiwany odczyt SEARCH. |
| `search_tolerance_m3` | `0.05` | Tolerancja dopasowania. |
| `search_delta_mode` | `false` | Dopasowanie po delcie od pierwszej obserwacji. |
| `search_min_delta_m3` | `0.001` | Minimalna delta dla `search_delta_mode`. |
| `search_topic` | `wmbus/search/candidates` | Topic, na który SEARCH pisze dopasowania. |
| `meters` | `[]` | Lista skonfigurowanych liczników. |
| `mqtt_mode` | `auto` | `auto`, `ha`, `external`. |
| `external_mqtt_host/port/username/password` | puste | Broker zewnętrzny (używany w `external` i fallbacku `auto`). |

Wpis licznika — jak w sekcji English.

### Pliki runtime, endpointy API, wykrywanie ESP, języki, licencja

Treść identyczna jak w sekcji English. Baza runtime: `/data` (HA) lub
`/config` (Docker). Wykrywanie ESP: główne źródło to RAW topic, wtórne
to `wmbus/+/diag/#`; ESP jest aktywny jeśli ma wpis w którymś źródle
w ostatnich 5 minutach. Licencja GNU GPL v3.0.

---

## Deutsch

### Pipeline

```
ESP-Empfänger → MQTT RAW HEX (Standard: wmbus/<device>/telegram)
             → bridge.sh (mosquitto_sub | awk-Hex-Filter | wmbusmeters)
             → MQTT-State (wmbusmeters/<id>/state)
             → MQTT-Discovery (homeassistant/…)
             → Home-Assistant-MQTT-Integration
```

Das Add-on implementiert keinen eigenen Decoder. Parsing und
Feldextraktion übernimmt das Upstream-`wmbusmeters`. Dieses Projekt
liefert MQTT-Verbindung, Konfigurationsverwaltung, Runtime-Status,
Home Assistant Discovery und die WebGUI.

### Komponenten, Modi, WebGUI-Routen, HA-Konfiguration, Docker

Inhaltlich identisch mit der englischen Sektion. `config.yaml` definiert:

- `ingress: true`, `ingress_port: 8099`
- `hassio_api: true`
- `panel_title: wMBus Bridge Dev`
- `services: [mqtt:want]`
- Standard-`raw_topic: wmbus/+/telegram`

`mqtt_mode`-Werte: `auto`, `ha`, `external`. Docker-Setup über
`docker/entrypoint.sh`, Standard-Datenverzeichnis `/config`,
WebGUI auf `WEBUI_PORT` (Standard `8099`).

### Konfigurationsoptionen

Standardwerte wie in `config.yaml`. Wichtige Optionen:

- `raw_topic` — MQTT-Topic für RAW HEX. `+`-Segment wird als ESP-Gerätename verwendet.
- `loglevel` — `normal` / `verbose` / `debug`.
- `filter_hex_only` — verwirft Nicht-HEX-Payloads und Payloads mit ungerader Länge.
- `discovery_enabled`, `discovery_prefix`, `discovery_retain` — Steuerung der HA-Discovery.
- `state_prefix`, `state_retain` — Veröffentlichung der dekodierten States.
- `meters` — Liste konfigurierter Zähler.
- `mqtt_mode` und `external_mqtt_*` — Broker-Auswahl.
- `search_*` — SEARCH-Workflow (Standard deaktiviert).

### Runtime-Dateien, API-Endpoints, ESP-Erkennung, Sprachen, Lizenz

Inhaltlich identisch mit der englischen Sektion. Runtime-Basis ist `/data`
(HA) bzw. `/config` (Docker). ESP-Erkennung primär über RAW-Topic,
sekundär über `wmbus/+/diag/#`; aktiv bei einem Eintrag in den letzten
5 Minuten. Lizenz: GNU GPL v3.0.

---

## Česky

### Pipeline

```
ESP přijímač → MQTT RAW HEX (výchozí wmbus/<device>/telegram)
            → bridge.sh (mosquitto_sub | awk hex filter | wmbusmeters)
            → MQTT state (wmbusmeters/<id>/state)
            → MQTT Discovery (homeassistant/…)
            → MQTT integrace v Home Assistant
```

Add-on neimplementuje vlastní dekodér. Parsování a extrakci polí dělá
upstream `wmbusmeters`. Tento projekt poskytuje MQTT vrstvu, správu
konfigurace, runtime stav, Home Assistant Discovery a WebGUI.

### Komponenty, režimy, trasy WebGUI, konfigurace HA, Docker

Obsahově shodné s anglickou sekcí. `config.yaml` deklaruje `ingress: true`,
`ingress_port: 8099`, `hassio_api: true`, `services: [mqtt:want]`, výchozí
`raw_topic: wmbus/+/telegram`. `mqtt_mode`: `auto`, `ha`, `external`.
Docker startuje přes `docker/entrypoint.sh`, výchozí datový adresář
`/config`, WebGUI na `WEBUI_PORT` (výchozí `8099`).

### Konfigurační volby, runtime soubory, API endpointy, detekce ESP, jazyky, licence

Obsahově shodné s anglickou sekcí. Runtime báze `/data` (HA) nebo `/config`
(Docker). Detekce ESP primárně z RAW topicu, sekundárně z `wmbus/+/diag/#`;
zařízení je aktivní pokud má záznam v některém zdroji v posledních 5
minutách. Licence GNU GPL v3.0.

---

## Slovenčina

### Pipeline

```
ESP prijímač → MQTT RAW HEX (predvolené wmbus/<device>/telegram)
            → bridge.sh (mosquitto_sub | awk hex filter | wmbusmeters)
            → MQTT state (wmbusmeters/<id>/state)
            → MQTT Discovery (homeassistant/…)
            → MQTT integrácia v Home Assistant
```

Add-on neimplementuje vlastný dekodér. Parsovanie a extrakciu polí robí
upstream `wmbusmeters`. Tento projekt poskytuje MQTT vrstvu, správu
konfigurácie, runtime stav, Home Assistant Discovery a WebGUI.

### Komponenty, režimy, trasy WebGUI, konfigurácia HA, Docker

Obsahovo zhodné s anglickou sekciou. `config.yaml` deklaruje
`ingress: true`, `ingress_port: 8099`, `hassio_api: true`,
`services: [mqtt:want]`, predvolený `raw_topic: wmbus/+/telegram`.
`mqtt_mode`: `auto`, `ha`, `external`. Docker štartuje cez
`docker/entrypoint.sh`, predvolený adresár dát `/config`,
WebGUI na `WEBUI_PORT` (predvolené `8099`).

### Konfiguračné voľby, runtime súbory, API endpointy, detekcia ESP, jazyky, licencia

Obsahovo zhodné s anglickou sekciou. Runtime báza `/data` (HA) alebo
`/config` (Docker). Detekcia ESP primárne z RAW topicu, sekundárne z
`wmbus/+/diag/#`; zariadenie je aktívne ak má záznam v niektorom zdroji
v posledných 5 minútach. Licencia GNU GPL v3.0.
