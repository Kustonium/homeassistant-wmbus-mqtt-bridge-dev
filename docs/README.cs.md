> [EN](README.en.md) | [PL](README.pl.md) | [DE](README.de.md) | [CS](README.cs.md) | [SK](README.sk.md)

# wMBus MQTT Bridge Dev - dokumentace CS

Popisovaná verze: `1.5.11-dev.45`.

Tento dokument nahrazuje popis starého WebGUI. Byl přepsán podle aktuální
logiky kódu v `bridge.sh`, `webui.py`, `app.js`, `config.yaml`, `run.sh` a
`docker/entrypoint.sh`.

Dokumentace staré verze měla pět jazykových souborů a tento stav zůstává:

- `docs/README.pl.md` - polština
- `docs/README.en.md` - angličtina
- `docs/README.de.md` - němčina
- `docs/README.cs.md` - čeština
- `docs/README.sk.md` - slovenština

Překlady jsou strojové a mohou obsahovat chyby.

## 1. Co add-on dělá

Add-on dekóduje telegramy Wireless M-Bus bez lokálního rádiového donglu u Home
Assistantu. Externí přijímač posílá surové HEX rámce přes MQTT a add-on je
předává do `wmbusmeters` přes `stdin:hex`.

Typický tok:

```text
ESP32 / gateway / bridge
  -> MQTT raw HEX: wmbus/+/telegram
  -> bridge.sh
  -> wmbusmeters --useconfig /data
  -> MQTT state: wmbusmeters/<id>/...
  -> Home Assistant MQTT Discovery: homeassistant/...
```

Projekt nenahrazuje dekodér `wmbusmeters`. Zajišťuje MQTT vstup, konfiguraci,
runtime stav, Home Assistant Discovery a WebGUI.

## 2. Hlavní komponenty

| Komponenta | Soubor | Úloha |
|---|---|---|
| `bridge.sh` | `rootfs/usr/bin/bridge.sh` | Odebírá RAW MQTT, spouští `wmbusmeters`, publikuje MQTT/Discovery a zapisuje runtime stav. |
| `webui.py` | `rootfs/usr/bin/webui.py` | HTTP/API server na portu `8099`, Ingress, API, SSE a akce WebGUI. |
| SPA WebGUI | `rootfs/usr/share/wmbus-webui/` | Statický frontend: `index.html`, `app.js`, `app.css`, `morphdom.min.js`. |
| HA start | `rootfs/usr/bin/run.sh` | Vybírá MQTT broker v režimu `auto`, `ha` nebo `external`. |
| Docker start | `docker/entrypoint.sh` | Vytváří `/config/options.json`, spouští `webui.py` a `bridge.sh`. |

## 3. Režimy bridge

- `LISTEN` - pokud je `meters` prázdné, add-on sbírá kandidáty a zapisuje
  `status_candidates.tsv`.
- `DECODE` - pokud `meters` obsahuje měřiče, `bridge.sh` vytvoří konfigurační
  soubory `wmbusmeters` a dekóduje nakonfigurovaná ID.
- `DECODE + parallel LISTEN` - po konfiguraci měřičů běží také paralelní LISTEN,
  aby WebGUI stále vidělo nové kandidáty.
- `SEARCH` - stále existuje v backendu a na skryté trase `#/search`, ale běžná
  identifikace je nyní v `#/discover`.

## 4. Dev WebUI

Nové WebGUI je statická SPA. `webui.py` servíruje soubory z
`/usr/share/wmbus-webui` a data poskytuje přes API.

| Endpoint | Metoda | Význam |
|---|---:|---|
| `/api/app` | GET | Kompletní model pro SPA včetně i18n. |
| `/api/events` | GET | Server-Sent Events pro live refresh. |
| `/api/status` | GET | Surový snapshot `state()`. |
| `/api/add-meter` | POST | Přidání měřiče do `options.json`. |
| `/api/remove-meter` | POST | Odebrání měřiče z `options.json`. |
| `/api/reload-pipeline` | POST | Dotkne se `.reload_pipeline`, měkký restart DECODE pipeline. |
| `/api/preview-candidate` | POST | Vytvoří dočasný meter-preview v LISTEN. |
| `/api/cancel-preview` | POST | Zruší preview a reloadne LISTEN. |
| `/api/ignore`, `/api/unignore` | POST | Skrýt/obnovit kandidáty. |
| `/api/restart-bridge` | POST | Restart add-onu přes Supervisor v HA. |
| `/api/search-control` | POST | Pokročilé řízení SEARCH. |

Live aktualizace používá `EventSource` na `/api/events`. Renderování je
patchováno pomocí `morphdom`, takže stránka nemá blikat a aktivní vstupy nemají
ztrácet focus. Pokud SSE není dostupné, frontend přejde na polling.

## 5. Zobrazení

| Trasa | Popis |
|---|---|
| `#/dashboard` | Výchozí stránka: pipeline nebo statistiky. |
| `#/meters` | Nakonfigurované měřiče a pending meters. |
| `#/discover` | Kandidáti, preview value, přidání, ignorování, filtry. |
| `#/logs` | Runtime události bridge/WebUI. |
| `#/esp-logs` | ESP diagnostika, eventy, návrhy a boot info. |
| `#/settings` | Konfigurace, runtime a snapshot pipeline. |
| `#/about` | Verze, režim běhu a cesty. |
| `#/search` | Pokročilé skryté SEARCH zobrazení. |

Dashboard ukládá volbu `pipeline` nebo `stats` do `localStorage`. Statistiky
obsahují logiku starého WebGUI: aktuální minuta, předchozí minuta, trend,
kandidáti, nakonfigurované měřiče, telegramy/min, sparkline a coverage/funnel.

## 6. Jazyky

WebGUI používá slovníky z `rootfs/usr/bin/i18n.py`.

Podporované jazyky:

- `en` - English
- `pl` - Polski
- `de` - Deutsch
- `cs` - Česky
- `sk` - Slovenčina

Pořadí detekce: parametr `?lang=`, cookie `wmbus_lang`, hlavička
`Accept-Language`, výchozí `en`.

## 7. Home Assistant

`config.yaml` popisuje add-on jako experimentální Dev:

- `name: wMBus MQTT Bridge Dev`
- `slug: wmbus_mqtt_bridge_dev`
- `ingress: true`
- `ingress_port: 8099`
- `hassio_api: true`
- `panel_title: wMBus Bridge Dev`

MQTT režimy:

| Volba | Význam |
|---|---|
| `mqtt_mode: auto` | Použít HA broker, pokud existuje, jinak externí nastavení. |
| `mqtt_mode: ha` | Vynutit Home Assistant broker. |
| `mqtt_mode: external` | Použít `external_mqtt_*`. |

Výchozí RAW topic v HA je `wmbus/+/telegram`.

## 8. Docker standalone

Docker běží bez Supervisor API. `docker/entrypoint.sh` nastaví `WMBUS_BASE`
výchozím `/config`, vytvoří `options.json`, načte MQTT nastavení, spustí WebGUI
na `WEBUI_PORT` (`8099`) a poté `bridge.sh`.

`/config` musí být zapisovatelný.

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

## 9. Důležité volby

| Volba | Výchozí | Popis |
|---|---:|---|
| `raw_topic` | `wmbus/+/telegram` v HA | Topic se surovým HEX. Dockerový default může být `wmbus_bridge/+/telegram`. |
| `loglevel` | `normal` | `normal`, `verbose`, `debug`. |
| `filter_hex_only` | `true` | Odmítat payloady, které nevypadají jako HEX. |
| `discovery_enabled` | `true` | Publikovat MQTT Discovery pro HA. |
| `discovery_prefix` | `homeassistant` | Discovery prefix. |
| `state_prefix` | `wmbusmeters` | MQTT state prefix. |
| `meters` | `[]` | Nakonfigurované měřiče. |
| `search_mode` | `false` | Pokročilé hledání podle fyzického odečtu. |

Příklad měřiče:

```json
{
  "id": "cold_water_bathroom",
  "meter_id": "41553221",
  "type": "mkradio3",
  "type_other": "",
  "key": ""
}
```

## 10. Runtime soubory

V Home Assistantu je základ `/data`, v Dockeru obvykle `/config`.

- `options.json` - uživatelská konfigurace.
- `status.json` - stav MQTT/pipeline/config.
- `status_meters.tsv` - dekódované nakonfigurované měřiče.
- `status_candidates.tsv` - LISTEN kandidáti.
- `status_events.tsv` - runtime události.
- `status_rate_1m.json`, `status_rate_history.tsv` - statistika telegramů.
- `status_candidate_values.tsv` - preview hodnoty kandidátů.
- `status_esp_telegram_devices.tsv` - aktivní ESP z RAW topicu.
- `status_esp_events.tsv`, `status_esp_diag.json` - ESP diagnostika.
- `.reload_pipeline`, `.reload_listen` - měkké reload flagy.

## 11. ESP diagnostika

Aktivní ESP se určují ze dvou zdrojů:

1. `status_esp_telegram_devices.tsv` - primární zdroj z `RAW_TOPIC`; segment
   odpovídající `+` je jméno zařízení.
2. `status_esp_events.tsv` a `status_esp_diag.json` - sekundární zdroj z
   `wmbus/+/diag/...`.

Zařízení je aktivní, pokud mělo RAW telegram nebo diag summary během posledních
5 minut.

## 12. Licence

Projekt je distribuován pod GNU GPL v3.0. Plný text je v `../LICENSE`.

Upstream:

- `wmbusmeters` - GPL-3.0
- `wmbusmeters-ha-addon` - GPL-3.0

Dev je inspirováno pracovním modelem Zigbee2MQTT: oddělený frontend, API a
live aktualizace. Aktuální lokální porovnání s `zigbee2mqtt-master` neukazuje
zkopírovaný Zigbee2MQTT kód ani assety. Pokud se později přidá skutečný Z2M
kód/assets, musí zůstat copyright notice, licence a označení změn podle GPL-3.0.

`morphdom.min.js` je přibalen pod MIT licencí. Detaily jsou v
`../THIRD_PARTY_NOTICES.md`.
