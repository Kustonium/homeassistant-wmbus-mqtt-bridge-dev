# RSSI per licznik i per ESP — zmiana z 2026-08-14

## Cel

Dwa lub więcej odbiorników ESP może odebrać ten sam telegram wM-Bus. Każda
płytka publikuje własny pomiar RSSI, a dodatek Home Assistant tworzy osobną
encję RSSI dla każdej płytki. Dzięki temu wartości nie nadpisują się i można
porównać jakość odbioru poszczególnych odbiorników.

## Strona ESP

Repozytorium: `Kustonium/esphome-wmbus-bridge-rawonly-dev`

Commit: `f50922f Add per-meter RSSI MQTT publishing`

Nowa opcja znajduje się w sekcji `wmbus_radio`:

```yaml
wmbus_radio:
  radio_type: SX1276
  listen_mode: t1
  topic_name: lilygo
  publish_rssi: true

  # Opcjonalna whitelista. Gdy jest wyłączona, publikowane są wszystkie
  # poprawnie zdekodowane liczniki.
  forward_meters: false
```

Każde ESP publikuje retained MQTT:

```text
wmbus/<topic_name>/rssi/<meter_id>
```

Przykład:

```text
wmbus/lilygo/rssi/03534159    payload: -52
wmbus/xiaoseed/rssi/03534159  payload: -50
```

Payload jest ujemną liczbą całkowitą w dBm. Publikowane są wyłącznie realne
pomiary od -125 do -1 dBm. Sentinele i ramki bez pomiaru są pomijane. Temat
telegramu nadal zawiera wyłącznie czysty HEX.

## Strona dodatku Home Assistant

Repozytorium: `Kustonium/homeassistant-wmbus-mqtt-bridge-dev`

Commit: `e48dd3e Add per-ESP RSSI entities`

Zmodyfikowane pliki:

- `rootfs/usr/bin/bridge-lib/13-esp.sh`
- `rootfs/usr/bin/bridge.sh`
- `tests/test_discovery_field_categories.sh`

Cache RSSI przechowuje teraz osobny wiersz dla każdej pary:

```text
<meter_id> + <nazwa ESP>
```

Nazwa urządzenia z tematu MQTT jest normalizowana do bezpiecznej nazwy pola:

```text
lilygo     -> rssi_lilygo_dbm
xiao-seed  -> rssi_xiao_seed_dbm
```

Dla przykładowego licznika Home Assistant otrzymuje:

```json
{
  "rssi_lilygo_dbm": -52,
  "rssi_xiaoseed_dbm": -50
}
```

Dynamiczne pola zakończone `_dbm` automatycznie tworzą osobne sensory z:

```text
unit_of_measurement: dBm
device_class: signal_strength
```

Scalone pola `rssi_dbm` i `rssi_source` zostały **usunięte** (2026-08-15).
Przy dwóch płytkach `rssi_dbm` pokazywał tę, która zgłosiła się jako ostatnia,
więc wartość skakała między odbiornikami. Zostają wyłącznie pola per płytka.
Retained config encji `rssi_dbm` jest kasowany przez `clean_legacy_entities()`
w `09-discovery.sh`, więc encja znika też w instalacjach, które ją już
utworzyły.

Wpis starszy niż 300 sekund jest ignorowany. Gdy konkretne ESP przestanie
publikować, jego pole znika z kolejnych stanów i odpowiadająca encja staje się
niedostępna.

## Weryfikacja

Test regresyjny sprawdza:

- dwa ESP odbierające ten sam licznik,
- dwie niezależne encje RSSI,
- aktualizację tylko właściwego wiersza cache,
- zachowanie pól kompatybilności,
- odrzucanie wartości niepoprawnych, sentinelowych i przeterminowanych,
- klasyfikację encji jako `signal_strength` w dBm,
- brak scalonych pól `rssi_dbm` / `rssi_source` w telegramie,
- skasowanie retained configu encji `rssi_dbm`.

Wynik testów:

```text
82 passed, 0 failed
```
