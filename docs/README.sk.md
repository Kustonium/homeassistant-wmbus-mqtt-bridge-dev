> [EN](README.en.md) | [PL](README.pl.md) | [DE](README.de.md) | [CS](README.cs.md) | [SK](README.sk.md)

# wMBus MQTT Bridge Dev - dokumentácia SK

Popisovaná verzia: `1.5.11-dev.45`.

Tento dokument nahrádza popis starého WebGUI. Bol prepísaný podľa aktuálnej
logiky kódu v `bridge.sh`, `webui.py`, `app.js`, `config.yaml`, `run.sh` a
`docker/entrypoint.sh`.

Dokumentácia starej verzie mala päť jazykových súborov a tento stav zostáva:

- `docs/README.pl.md` - poľština
- `docs/README.en.md` - angličtina
- `docs/README.de.md` - nemčina
- `docs/README.cs.md` - čeština
- `docs/README.sk.md` - slovenčina

Preklady sú strojové a môžu obsahovať chyby.

## 1. Čo add-on robí

Add-on dekóduje telegramy Wireless M-Bus bez lokálneho rádiového donglu pri Home
Assistante. Externý prijímač posiela surové HEX rámce cez MQTT a add-on ich
odovzdáva do `wmbusmeters` cez `stdin:hex`.

Typický tok:

```text
ESP32 / gateway / bridge
  -> MQTT raw HEX: wmbus/+/telegram
  -> bridge.sh
  -> wmbusmeters --useconfig /data
  -> MQTT state: wmbusmeters/<id>/...
  -> Home Assistant MQTT Discovery: homeassistant/...
```

Projekt nenahrádza dekodér `wmbusmeters`. Zabezpečuje MQTT vstup, konfiguráciu,
runtime stav, Home Assistant Discovery a WebGUI.

## 2. Hlavné komponenty

| Komponent | Súbor | Úloha |
|---|---|---|
| `bridge.sh` | `rootfs/usr/bin/bridge.sh` | Odoberá RAW MQTT, spúšťa `wmbusmeters`, publikuje MQTT/Discovery a zapisuje runtime stav. |
| `webui.py` | `rootfs/usr/bin/webui.py` | HTTP/API server na porte `8099`, Ingress, API, SSE a akcie WebGUI. |
| SPA WebGUI | `rootfs/usr/share/wmbus-webui/` | Statický frontend: `index.html`, `app.js`, `app.css`, `morphdom.min.js`. |
| HA start | `rootfs/usr/bin/run.sh` | Vyberá MQTT broker v režime `auto`, `ha` alebo `external`. |
| Docker start | `docker/entrypoint.sh` | Vytvára `/config/options.json`, spúšťa `webui.py` a `bridge.sh`. |

## 3. Režimy bridge

- `LISTEN` - ak je `meters` prázdne, add-on zbiera kandidátov a zapisuje
  `status_candidates.tsv`.
- `DECODE` - ak `meters` obsahuje merače, `bridge.sh` vytvorí konfiguračné
  súbory `wmbusmeters` a dekóduje nakonfigurované ID.
- `DECODE + parallel LISTEN` - po konfigurácii meračov beží aj paralelný LISTEN,
  aby WebGUI stále videlo nových kandidátov.
- `SEARCH` - stále existuje v backende a na skrytej trase `#/search`, ale bežná
  identifikácia je teraz v `#/discover`.

## 4. Dev WebUI

Nové WebGUI je statická SPA. `webui.py` servíruje súbory z
`/usr/share/wmbus-webui` a dáta poskytuje cez API.

| Endpoint | Metóda | Význam |
|---|---:|---|
| `/api/app` | GET | Kompletný model pre SPA vrátane i18n. |
| `/api/events` | GET | Server-Sent Events pre live refresh. |
| `/api/status` | GET | Surový snapshot `state()`. |
| `/api/add-meter` | POST | Pridanie merača do `options.json`. |
| `/api/remove-meter` | POST | Odstránenie merača z `options.json`. |
| `/api/reload-pipeline` | POST | Dotkne sa `.reload_pipeline`, mäkký restart DECODE pipeline. |
| `/api/preview-candidate` | POST | Vytvorí dočasný meter-preview v LISTEN. |
| `/api/cancel-preview` | POST | Zruší preview a reloadne LISTEN. |
| `/api/ignore`, `/api/unignore` | POST | Skryť/obnoviť kandidátov. |
| `/api/restart-bridge` | POST | Restart add-onu cez Supervisor v HA. |
| `/api/search-control` | POST | Pokročilé riadenie SEARCH. |

Live aktualizácia používa `EventSource` na `/api/events`. Renderovanie je
patchované pomocou `morphdom`, takže stránka nemá blikať a aktívne vstupy nemajú
strácať focus. Ak SSE nie je dostupné, frontend prejde na polling.

## 5. Zobrazenia

| Trasa | Popis |
|---|---|
| `#/dashboard` | Predvolená stránka: pipeline alebo štatistiky. |
| `#/meters` | Nakonfigurované merače a pending meters. |
| `#/discover` | Kandidáti, preview value, pridanie, ignorovanie, filtre. |
| `#/logs` | Runtime udalosti bridge/WebUI. |
| `#/esp-logs` | ESP diagnostika, eventy, návrhy a boot info. |
| `#/settings` | Konfigurácia, runtime a snapshot pipeline. |
| `#/about` | Verzia, režim behu a cesty. |
| `#/search` | Pokročilé skryté SEARCH zobrazenie. |

Dashboard ukladá voľbu `pipeline` alebo `stats` do `localStorage`. Štatistiky
obsahujú logiku starého WebGUI: aktuálna minúta, predchádzajúca minúta, trend,
kandidáti, nakonfigurované merače, telegramy/min, sparkline a coverage/funnel.

## 6. Jazyky

WebGUI používa slovníky z `rootfs/usr/bin/i18n.py`.

Podporované jazyky:

- `en` - English
- `pl` - Polski
- `de` - Deutsch
- `cs` - Česky
- `sk` - Slovenčina

Poradie detekcie: parameter `?lang=`, cookie `wmbus_lang`, hlavička
`Accept-Language`, predvolene `en`.

## 7. Home Assistant

`config.yaml` popisuje add-on ako experimentálne Dev:

- `name: wMBus MQTT Bridge Dev`
- `slug: wmbus_mqtt_bridge_dev`
- `ingress: true`
- `ingress_port: 8099`
- `hassio_api: true`
- `panel_title: wMBus Bridge Dev`

MQTT režimy:

| Voľba | Význam |
|---|---|
| `mqtt_mode: auto` | Použiť HA broker, ak existuje, inak externé nastavenia. |
| `mqtt_mode: ha` | Vynútiť Home Assistant broker. |
| `mqtt_mode: external` | Použiť `external_mqtt_*`. |

Predvolený RAW topic v HA je `wmbus/+/telegram`.

## 8. Docker standalone

Docker beží bez Supervisor API. `docker/entrypoint.sh` nastaví `WMBUS_BASE`
predvolene na `/config`, vytvorí `options.json`, načíta MQTT nastavenia, spustí
WebGUI na `WEBUI_PORT` (`8099`) a potom `bridge.sh`.

`/config` musí byť zapisovateľný.

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

## 9. Dôležité voľby

| Voľba | Predvolené | Popis |
|---|---:|---|
| `raw_topic` | `wmbus/+/telegram` v HA | Topic so surovým HEX. Dockerový default môže byť `wmbus_bridge/+/telegram`. |
| `loglevel` | `normal` | `normal`, `verbose`, `debug`. |
| `filter_hex_only` | `true` | Odmietať payloady, ktoré nevyzerajú ako HEX. |
| `discovery_enabled` | `true` | Publikovať MQTT Discovery pre HA. |
| `discovery_prefix` | `homeassistant` | Discovery prefix. |
| `state_prefix` | `wmbusmeters` | MQTT state prefix. |
| `meters` | `[]` | Nakonfigurované merače. |
| `search_mode` | `false` | Pokročilé hľadanie podľa fyzického odpočtu. |

Príklad merača:

```json
{
  "id": "cold_water_bathroom",
  "meter_id": "41553221",
  "type": "mkradio3",
  "type_other": "",
  "key": ""
}
```

## 10. Runtime súbory

V Home Assistante je základ `/data`, v Dockeri obvykle `/config`.

- `options.json` - používateľská konfigurácia.
- `status.json` - stav MQTT/pipeline/config.
- `status_meters.tsv` - dekódované nakonfigurované merače.
- `status_candidates.tsv` - LISTEN kandidáti.
- `status_events.tsv` - runtime udalosti.
- `status_rate_1m.json`, `status_rate_history.tsv` - štatistika telegramov.
- `status_candidate_values.tsv` - preview hodnoty kandidátov.
- `status_esp_telegram_devices.tsv` - aktívne ESP z RAW topicu.
- `status_esp_events.tsv`, `status_esp_diag.json` - ESP diagnostika.
- `.reload_pipeline`, `.reload_listen` - mäkké reload flagy.

## 11. ESP diagnostika

Aktívne ESP sa určujú z dvoch zdrojov:

1. `status_esp_telegram_devices.tsv` - primárny zdroj z `RAW_TOPIC`; segment
   zodpovedajúci `+` je meno zariadenia.
2. `status_esp_events.tsv` a `status_esp_diag.json` - sekundárny zdroj z
   `wmbus/+/diag/...`.

Zariadenie je aktívne, ak malo RAW telegram alebo diag summary počas posledných
5 minút.

## 12. Licencia

Projekt je distribuovaný pod GNU GPL v3.0. Plný text je v `../LICENSE`.

Upstream:

- `wmbusmeters` - GPL-3.0
- `wmbusmeters-ha-addon` - GPL-3.0

Dev je inšpirované pracovným modelom Zigbee2MQTT: oddelený frontend, API a
live aktualizácie. Aktuálne lokálne porovnanie s `zigbee2mqtt-master`
neukazuje skopírovaný Zigbee2MQTT kód ani assety. Ak sa neskôr pridá skutočný
Z2M kód/assets, musia zostať copyright notice, licencia a označenia zmien podľa
GPL-3.0.

`morphdom.min.js` je pribalený pod MIT licenciou. Detaily sú v
`../THIRD_PARTY_NOTICES.md`.
