> [EN](README.en.md) | [PL](README.pl.md) | [DE](README.de.md) | [CS](README.cs.md) | [SK](README.sk.md)

# wMBus MQTT Bridge Dev - dokumentacja PL

Wersja opisana w tym dokumencie: `1.5.11-dev.45`.

Ten dokument zastępuje opis starego WebGUI. Został przeredagowany na podstawie
aktualnej logiki kodu w `bridge.sh`, `webui.py`, `app.js`, `config.yaml`,
`run.sh` i `docker/entrypoint.sh`.

Dokumentacja starej wersji była utrzymywana w pięciu językach i ten układ
zostaje zachowany:

- `docs/README.pl.md` - polski
- `docs/README.en.md` - angielski
- `docs/README.de.md` - niemiecki
- `docs/README.cs.md` - czeski
- `docs/README.sk.md` - słowacki

Tłumaczenia są generowane maszynowo i mogą zawierać błędy także w PL i EN.

## 1. Co robi add-on

Add-on dekoduje telegramy Wireless M-Bus bez lokalnego odbiornika radiowego
podłączonego do Home Assistant. Surowe ramki HEX przychodzą z MQTT, a add-on
podaje je do `wmbusmeters` przez `stdin:hex`.

Typowy pipeline:

```text
ESP32 / gateway / bridge
  -> MQTT raw HEX: wmbus/+/telegram
  -> bridge.sh
  -> wmbusmeters --useconfig /data
  -> MQTT state: wmbusmeters/<id>/...
  -> Home Assistant MQTT Discovery: homeassistant/...
```

Projekt nie zastępuje dekodera `wmbusmeters`. Projekt organizuje wejście MQTT,
konfigurację, status runtime, Home Assistant Discovery i WebGUI.

## 2. Główne komponenty

| Komponent | Plik | Rola |
|---|---|---|
| `bridge.sh` | `rootfs/usr/bin/bridge.sh` | Subskrybuje RAW MQTT, uruchamia `wmbusmeters`, publikuje MQTT/Discovery i zapisuje statusy runtime. |
| `webui.py` | `rootfs/usr/bin/webui.py` | Serwer HTTP/API na porcie `8099`, obsługa Ingress, API, SSE, akcje WebGUI. |
| SPA WebGUI | `rootfs/usr/share/wmbus-webui/` | Statyczny frontend: `index.html`, `app.js`, `app.css`, `morphdom.min.js`. |
| HA start | `rootfs/usr/bin/run.sh` | Dobiera broker MQTT w trybie `auto`, `ha` albo `external`. |
| Docker start | `docker/entrypoint.sh` | Tworzy `/config/options.json`, startuje `webui.py` i `bridge.sh`. |

## 3. Tryby pracy bridge

### LISTEN

Gdy `meters` jest puste, add-on słucha wszystkich telegramów i zapisuje
kandydatów w `status_candidates.tsv`. To jest tryb pierwszego uruchomienia.

### DECODE

Gdy `meters` zawiera co najmniej jeden licznik, `bridge.sh` generuje pliki
konfiguracji `wmbusmeters` w `/data/etc/wmbusmeters.d/`, dekoduje pasujące ID i
publikuje wyniki do MQTT oraz Home Assistant Discovery.

### DECODE + równoległy LISTEN

Po skonfigurowaniu liczników działa również równoległa instancja LISTEN. Dzięki
temu WebGUI nadal widzi kandydatów z eteru, a główny pipeline dekoduje
skonfigurowane liczniki.

### SEARCH

Tryb SEARCH nadal istnieje w backendzie i w ukrytej trasie `#/search`. Służy do
porównywania odczytu z fizycznego licznika z dekodowanymi kandydatami. W nowym
WebGUI główną ścieżką identyfikacji jest jednak `#/discover`: preview value,
filtr po wartości i dodawanie z tabeli.

## 4. Dev WebUI

Nowe WebGUI jest statyczną aplikacją SPA. `webui.py` serwuje pliki z
`/usr/share/wmbus-webui`, a dane dostarcza przez API.

Najważniejsze endpointy:

| Endpoint | Metoda | Znaczenie |
|---|---:|---|
| `/api/app` | GET | Pełny model danych dla SPA, razem z i18n. |
| `/api/events` | GET | Server-Sent Events dla live refresh. |
| `/api/status` | GET | Surowy snapshot `state()`. |
| `/api/add-meter` | POST | Dodanie licznika do `options.json`. |
| `/api/remove-meter` | POST | Usunięcie licznika z `options.json`. |
| `/api/reload-pipeline` | POST | Dotyka `.reload_pipeline`, miękki restart DECODE pipeline. |
| `/api/preview-candidate` | POST | Tworzy tymczasowy meter-preview w LISTEN. |
| `/api/cancel-preview` | POST | Usuwa preview i przeładowuje LISTEN. |
| `/api/ignore`, `/api/unignore` | POST | Ukrywanie/przywracanie kandydatów. |
| `/api/restart-bridge` | POST | Restart add-onu przez Supervisor, gdy działa w HA. |
| `/api/search-control` | POST | Zaawansowane sterowanie SEARCH. |

### Live refresh

Frontend otwiera `EventSource` do `/api/events`. Backend wysyła nowy payload,
gdy zmieni się stan, oraz heartbeat. Renderowanie jest patchowane przez
`morphdom`, więc ekran nie powinien migać ani tracić fokusu w aktywnym polu.
Gdy `EventSource` nie działa, frontend przechodzi na polling.

### Widoki

| Trasa | Opis |
|---|---|
| `#/dashboard` | Domyślny ekran. Przełącznik: pipeline albo statystyki. |
| `#/meters` | Skonfigurowane liczniki, pending meters, usuwanie. |
| `#/discover` | Kandydaci, preview value, dodawanie, ignorowanie, filtr po mediach i wartości. |
| `#/logs` | Zdarzenia runtime zapisane przez bridge/WebUI. |
| `#/esp-logs` | ESP diagnostics, wydarzenia ESP, sugestie i boot info. |
| `#/settings` | Snapshot konfiguracji, runtime i status pipeline. |
| `#/about` | Informacje o wersji, trybie uruchomienia i ścieżkach. |
| `#/search` | Zaawansowany, ukryty widok SEARCH. |

### Dashboard

Dashboard ma dwa tryby, zapamiętywane w `localStorage`:

- `pipeline` - cztery węzły: ESP, MQTT, wMBus, Home Assistant. Kliknięcie węzła
  otwiera panel szczegółów.
- `stats` - stara logika statystyk przeniesiona do nowego UI: bieżąca minuta,
  poprzednia minuta, trend, kandydaci, skonfigurowane liczniki, telegramy/min,
  sparkline i coverage/funnel.

## 5. Języki

WebGUI używa słowników z `rootfs/usr/bin/i18n.py`.

Obsługiwane języki:

- `en` - English
- `pl` - Polski
- `de` - Deutsch
- `cs` - Česky
- `sk` - Slovenčina

Kolejność wykrywania języka:

1. parametr `?lang=`
2. cookie `wmbus_lang`
3. nagłówek `Accept-Language`
4. domyślnie `en`

Nowy frontend nie ma osobnych plików tłumaczeń. Dostaje słownik z `/api/app`,
a brakujące lokalne aliasy mapuje w `app.js` na istniejące klucze.

## 6. Home Assistant

Add-on jest opisany w `config.yaml` jako eksperymentalny Dev:

- `name: wMBus MQTT Bridge Dev`
- `slug: wmbus_mqtt_bridge_dev`
- `ingress: true`
- `ingress_port: 8099`
- `hassio_api: true`
- `panel_title: wMBus Bridge Dev`

Opcje MQTT:

| Opcja | Znaczenie |
|---|---|
| `mqtt_mode: auto` | Użyj brokera HA, jeśli jest dostępny, inaczej external. |
| `mqtt_mode: ha` | Wymuś broker Home Assistant. |
| `mqtt_mode: external` | Użyj ustawień `external_mqtt_*`. |

Domyślny topic RAW w HA to `wmbus/+/telegram`.

## 7. Docker standalone

Docker działa bez Supervisor API. `docker/entrypoint.sh`:

1. ustawia `WMBUS_BASE`, domyślnie `/config`,
2. tworzy `/config/options.json`, jeśli go nie ma,
3. czyta z niego `external_mqtt_*`,
4. eksportuje `MQTT_HOST`, `MQTT_PORT`, `MQTT_USER`, `MQTT_PASS`,
5. startuje WebGUI na `WEBUI_PORT`, domyślnie `8099`,
6. uruchamia `bridge.sh`.

W Dockerze katalog `/config` musi być zapisywalny. WebGUI i bridge zapisują tam
statusy, konfigurację i pliki `wmbusmeters`.

Przykład:

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

## 8. Najważniejsze opcje

| Opcja | Domyślnie | Opis |
|---|---:|---|
| `raw_topic` | `wmbus/+/telegram` w HA | Topic z surowym HEX. W Dockerowym default file może być `wmbus_bridge/+/telegram`. |
| `loglevel` | `normal` | `normal`, `verbose`, `debug`. |
| `filter_hex_only` | `true` | Odrzucanie payloadów, które nie wyglądają jak HEX. |
| `discovery_enabled` | `true` | Publikowanie MQTT Discovery dla HA. |
| `discovery_prefix` | `homeassistant` | Prefix discovery. |
| `state_prefix` | `wmbusmeters` | Prefix stanów MQTT. |
| `state_retain` | `false` | Retain dla stanów. |
| `meters` | `[]` | Lista skonfigurowanych liczników. |
| `search_mode` | `false` | Zaawansowane dopasowanie po odczycie. |
| `search_expected_value_m3` | `0` | Oczekiwany stan licznika w m3. |
| `search_tolerance_m3` | `0.05` | Tolerancja SEARCH. |

Wpis licznika:

```json
{
  "id": "cold_water_bathroom",
  "meter_id": "41553221",
  "type": "mkradio3",
  "type_other": "",
  "key": ""
}
```

`meter_id` musi być 8-znakowym ID. `key` zostaw puste dla liczników
nieszyfrowanych albo wpisz 32 znaki HEX dla AES.

## 9. Pliki runtime

| Plik | Pisze | Czyta | Znaczenie |
|---|---|---|---|
| `options.json` | HA/Docker/WebGUI | `bridge.sh`, `webui.py` | Konfiguracja użytkownika. |
| `status.json` | `bridge.sh` | `webui.py` | Status MQTT, pipeline i config. |
| `status_meters.tsv` | `bridge.sh` | `webui.py` | Skonfigurowane liczniki po dekodzie. |
| `status_candidates.tsv` | `bridge.sh` | `webui.py` | Kandydaci z LISTEN. |
| `status_events.tsv` | `bridge.sh`, `webui.py` | `webui.py` | Zdarzenia runtime. |
| `status_seen.tsv` | `bridge.sh` | `bridge.sh` | Statystyki widoczności ID. |
| `status_rate_1m.json` | `bridge.sh` | `webui.py` | Bieżąca i poprzednia minuta. |
| `status_rate_history.tsv` | `bridge.sh` | `webui.py` | Historia 15 minut dla wykresu. |
| `status_candidate_analysis.tsv` | `bridge.sh` | `webui.py` | Analiza szyfrowania kandydatów. |
| `status_candidate_values.tsv` | `bridge.sh` | `webui.py` | Preview value kandydatów. |
| `status_esp_telegram_devices.tsv` | `bridge.sh` | `webui.py` | Aktywne ESP wykryte z RAW topicu. |
| `status_esp_events.tsv` | `bridge.sh` | `webui.py` | Zdarzenia ESP diag. |
| `status_esp_diag.json` | `bridge.sh` | `webui.py` | Ostatni summary ESP. |
| `.reload_pipeline` | `webui.py` | `bridge.sh` | Miękki restart DECODE pipeline. |
| `.reload_listen` | `webui.py` | `bridge.sh` | Restart równoległego LISTEN. |

## 10. ESP diagnostics

Aktywne ESP są wykrywane z dwóch źródeł:

1. `status_esp_telegram_devices.tsv` - źródło podstawowe. `bridge.sh` słucha
   `RAW_TOPIC`; segment pasujący do `+` jest nazwą urządzenia, np.
   `wmbus/xiaoseed/telegram`.
2. `status_esp_events.tsv` i `status_esp_diag.json` - źródło dodatkowe z
   `wmbus/+/diag/...`.

Urządzenie jest aktywne, jeśli miało telegram RAW albo summary diag w ostatnich
5 minutach. Dzięki temu stare retained messages z MQTT nie powinny udawać
żywego ESP.

## 11. Licencja

Projekt jest dystrybuowany na GNU GPL v3.0. Pełny tekst jest w `../LICENSE`.

Upstream:

- `wmbusmeters` - GPL-3.0
- `wmbusmeters-ha-addon` - GPL-3.0

Dev jest inspirowany sposobem działania Zigbee2MQTT: osobny frontend, API i
live update. Aktualne porównanie z lokalnym `zigbee2mqtt-master` nie wskazuje,
żeby w repo znajdował się skopiowany kod lub assety Zigbee2MQTT. Jeżeli w
przyszłości zostanie dodany realny kod/assets z Z2M, trzeba zachować notice,
licencję i oznaczenia modyfikacji zgodnie z GPL-3.0.

`morphdom.min.js` jest dołączony jako biblioteka MIT. Szczegóły są w
`../THIRD_PARTY_NOTICES.md`.
