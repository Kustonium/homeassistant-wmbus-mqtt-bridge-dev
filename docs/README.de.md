> [EN](README.en.md) | [PL](README.pl.md) | [DE](README.de.md) | [CS](README.cs.md) | [SK](README.sk.md)

# wMBus MQTT Bridge Dev - Dokumentation DE

Beschriebene Version: `1.5.11-dev.45`.

Dieses Dokument ersetzt die Beschreibung des alten WebGUI. Es wurde anhand der
aktuellen Code-Logik in `bridge.sh`, `webui.py`, `app.js`, `config.yaml`,
`run.sh` und `docker/entrypoint.sh` neu geschrieben.

Die alte Dokumentation hatte fünf Sprachdateien. Diese Struktur bleibt erhalten:

- `docs/README.pl.md` - Polnisch
- `docs/README.en.md` - Englisch
- `docs/README.de.md` - Deutsch
- `docs/README.cs.md` - Tschechisch
- `docs/README.sk.md` - Slowakisch

Die Übersetzungen sind maschinell erstellt und können Fehler enthalten.

## 1. Zweck des Add-ons

Das Add-on dekodiert Wireless-M-Bus-Telegramme ohne lokalen Funkdongle am Home
Assistant Host. Externe Empfänger liefern rohe HEX-Frames über MQTT, und das
Add-on übergibt diese Frames an `wmbusmeters` über `stdin:hex`.

Typischer Datenfluss:

```text
ESP32 / Gateway / Bridge
  -> MQTT raw HEX: wmbus/+/telegram
  -> bridge.sh
  -> wmbusmeters --useconfig /data
  -> MQTT state: wmbusmeters/<id>/...
  -> Home Assistant MQTT Discovery: homeassistant/...
```

Das Projekt ersetzt `wmbusmeters` nicht. Es liefert MQTT-Eingang,
Konfiguration, Runtime-Status, Home Assistant Discovery und das WebGUI.

## 2. Hauptkomponenten

| Komponente | Datei | Aufgabe |
|---|---|---|
| `bridge.sh` | `rootfs/usr/bin/bridge.sh` | Abonniert RAW MQTT, startet `wmbusmeters`, publiziert MQTT/Discovery und schreibt Runtime-Status. |
| `webui.py` | `rootfs/usr/bin/webui.py` | HTTP/API-Server auf Port `8099`, Ingress, API, SSE und WebGUI-Aktionen. |
| SPA WebGUI | `rootfs/usr/share/wmbus-webui/` | Statisches Frontend: `index.html`, `app.js`, `app.css`, `morphdom.min.js`. |
| HA Start | `rootfs/usr/bin/run.sh` | Wählt MQTT-Broker im Modus `auto`, `ha` oder `external`. |
| Docker Start | `docker/entrypoint.sh` | Erstellt `/config/options.json`, startet `webui.py` und `bridge.sh`. |

## 3. Bridge-Modi

- `LISTEN` - wenn `meters` leer ist, sammelt das Add-on Kandidaten und schreibt
  `status_candidates.tsv`.
- `DECODE` - wenn `meters` Einträge enthält, erzeugt `bridge.sh`
  `wmbusmeters`-Konfigurationsdateien und dekodiert konfigurierte IDs.
- `DECODE + parallel LISTEN` - nach der Konfiguration läuft zusätzlich eine
  LISTEN-Instanz, damit das WebGUI weiterhin neue Kandidaten sieht.
- `SEARCH` - weiterhin vorhanden, aber als erweiterter/verborgener Workflow
  unter `#/search`. Der normale Workflow läuft jetzt über `#/discover`.

## 4. Dev WebUI

Das neue WebGUI ist eine statische SPA. `webui.py` liefert die Dateien aus
`/usr/share/wmbus-webui` und stellt Daten über API-Endpunkte bereit.

| Endpoint | Methode | Bedeutung |
|---|---:|---|
| `/api/app` | GET | Komplettes Datenmodell für die SPA, inklusive i18n. |
| `/api/events` | GET | Server-Sent Events für Live-Aktualisierung. |
| `/api/status` | GET | Roher Snapshot von `state()`. |
| `/api/add-meter` | POST | Zähler zu `options.json` hinzufügen. |
| `/api/remove-meter` | POST | Zähler aus `options.json` entfernen. |
| `/api/reload-pipeline` | POST | `.reload_pipeline` berühren, DECODE-Pipeline weich neu starten. |
| `/api/preview-candidate` | POST | Temporäres meter-preview in LISTEN anlegen. |
| `/api/cancel-preview` | POST | Preview entfernen und LISTEN neu laden. |
| `/api/ignore`, `/api/unignore` | POST | Kandidaten ausblenden/wiederherstellen. |
| `/api/restart-bridge` | POST | Add-on über Supervisor neu starten, wenn HA verfügbar ist. |
| `/api/search-control` | POST | Erweiterte SEARCH-Steuerung. |

Live-Aktualisierung läuft über `EventSource` auf `/api/events`. Das Rendering
wird mit `morphdom` gepatcht, damit die Seite nicht flackert und aktive Eingaben
nicht verloren gehen. Wenn SSE nicht verfügbar ist, nutzt das Frontend Polling.

## 5. Ansichten

| Route | Beschreibung |
|---|---|
| `#/dashboard` | Standardansicht: Pipeline oder Statistik. |
| `#/meters` | Konfigurierte Zähler und pending meters. |
| `#/discover` | Kandidaten, Preview Value, Hinzufügen, Ignorieren, Filter. |
| `#/logs` | Runtime-Ereignisse von Bridge/WebUI. |
| `#/esp-logs` | ESP-Diagnose, Events, Vorschläge und Boot-Info. |
| `#/settings` | Konfiguration, Runtime und Pipeline-Snapshot. |
| `#/about` | Version, Runtime-Modus und Pfade. |
| `#/search` | Erweiterte versteckte SEARCH-Ansicht. |

Das Dashboard speichert die Auswahl `pipeline` oder `stats` in `localStorage`.
Die Statistikansicht enthält die alte WebGUI-Logik: aktuelle Minute, vorherige
Minute, Trend, Kandidaten, konfigurierte Zähler, Telegramme/min, Sparkline und
Coverage/Funnel.

## 6. Sprachen

Das WebGUI verwendet Wörterbücher aus `rootfs/usr/bin/i18n.py`.

Unterstützte Sprachen:

- `en` - English
- `pl` - Polski
- `de` - Deutsch
- `cs` - Česky
- `sk` - Slovenčina

Erkennungsreihenfolge: `?lang=`, Cookie `wmbus_lang`, Header
`Accept-Language`, Standard `en`.

## 7. Home Assistant

`config.yaml` beschreibt das Add-on als experimentelles Dev:

- `name: wMBus MQTT Bridge Dev`
- `slug: wmbus_mqtt_bridge_dev`
- `ingress: true`
- `ingress_port: 8099`
- `hassio_api: true`
- `panel_title: wMBus Bridge Dev`

MQTT-Modi:

| Option | Bedeutung |
|---|---|
| `mqtt_mode: auto` | HA-Broker verwenden, wenn verfügbar, sonst externe Einstellungen. |
| `mqtt_mode: ha` | Home Assistant Broker erzwingen. |
| `mqtt_mode: external` | `external_mqtt_*` verwenden. |

Der Standard-RAW-Topic in HA ist `wmbus/+/telegram`.

## 8. Docker standalone

Docker läuft ohne Supervisor API. `docker/entrypoint.sh` setzt `WMBUS_BASE`
standardmäßig auf `/config`, erstellt `options.json`, liest MQTT-Einstellungen,
startet WebGUI auf `WEBUI_PORT` (`8099`) und danach `bridge.sh`.

`/config` muss schreibbar sein.

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

## 9. Wichtige Optionen

| Option | Standard | Beschreibung |
|---|---:|---|
| `raw_topic` | `wmbus/+/telegram` in HA | Topic mit rohem HEX. Docker kann im Default-File `wmbus_bridge/+/telegram` verwenden. |
| `loglevel` | `normal` | `normal`, `verbose`, `debug`. |
| `filter_hex_only` | `true` | Payloads verwerfen, die nicht wie HEX aussehen. |
| `discovery_enabled` | `true` | MQTT Discovery für HA publizieren. |
| `discovery_prefix` | `homeassistant` | Discovery-Prefix. |
| `state_prefix` | `wmbusmeters` | MQTT-State-Prefix. |
| `meters` | `[]` | Konfigurierte Zähler. |
| `search_mode` | `false` | Erweiterte Suche nach physischem Zählerstand. |

Beispiel-Zähler:

```json
{
  "id": "cold_water_bathroom",
  "meter_id": "41553221",
  "type": "mkradio3",
  "type_other": "",
  "key": ""
}
```

## 10. Runtime-Dateien

W Home Assistant ist die Basis `/data`, in Docker meistens `/config`.

- `options.json` - Benutzerkonfiguration.
- `status.json` - MQTT/Pipeline/Config-Status.
- `status_meters.tsv` - dekodierte konfigurierte Zähler.
- `status_candidates.tsv` - LISTEN-Kandidaten.
- `status_events.tsv` - Runtime-Ereignisse.
- `status_rate_1m.json`, `status_rate_history.tsv` - Telegrammstatistik.
- `status_candidate_values.tsv` - Preview-Werte der Kandidaten.
- `status_esp_telegram_devices.tsv` - aktive ESPs aus RAW-Topic.
- `status_esp_events.tsv`, `status_esp_diag.json` - ESP-Diagnose.
- `.reload_pipeline`, `.reload_listen` - weiche Reload-Flags.

## 11. ESP-Diagnose

Aktive ESPs werden aus zwei Quellen ermittelt:

1. `status_esp_telegram_devices.tsv` - primäre Quelle aus `RAW_TOPIC`; das
   Segment, das auf `+` passt, ist der Gerätename.
2. `status_esp_events.tsv` und `status_esp_diag.json` - sekundäre Quelle aus
   `wmbus/+/diag/...`.

Ein Gerät ist aktiv, wenn es in den letzten 5 Minuten ein RAW-Telegramm oder ein
Diag-Summary hatte.

## 12. Lizenz

Das Projekt steht unter GNU GPL v3.0. Der vollständige Text steht in `../LICENSE`.

Upstream:

- `wmbusmeters` - GPL-3.0
- `wmbusmeters-ha-addon` - GPL-3.0

Dev ist vom Arbeitsmodell von Zigbee2MQTT inspiriert: getrenntes Frontend,
API und Live-Updates. Der aktuelle lokale Vergleich mit `zigbee2mqtt-master`
zeigt keinen kopierten Zigbee2MQTT-Code und keine kopierten Assets. Falls später
echter Z2M-Code oder Assets übernommen werden, müssen Copyright-Hinweise,
Lizenztext und Änderungshinweise gemäß GPL-3.0 erhalten bleiben.

`morphdom.min.js` ist unter MIT-Lizenz gebündelt. Details stehen in
`../THIRD_PARTY_NOTICES.md`.
