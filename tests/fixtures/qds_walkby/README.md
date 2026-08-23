# Qundis walk-by corpus — TCP injection

Ten korpus testuje **sam dekoder i klasyfikator**, bez radia. Wszystkie ramki są
strukturalnie poprawne (L-field zgodny, parzysta długość, tylko znaki hex), więc
przechodzą przez filtr wejściowy dodatku, ale **nie należą do zwykłego replaya** —
zawierają celowo nieczytelne bloki producenta. Zgodnie z `CLAUDE.md` §11 trzymamy je
osobno od `01_strict_replay_all_validated.txt`.

Ramka Format A z CRC-ami należy do ścieżki RF (fake T), nie tutaj — jest jako
`FormatACrc` w `tests/test_qds_walkby.py`.

## Przygotowanie

Włącz opcję i skonfiguruj **jeden** licznik. Drugi (`60555886`) zostaw
nieskonfigurowany — na tym polega przypadek 06.

```
qds_walkby_enabled: true
meters:
  - name: QdsTest
    id: "60555885"
    driver: qwaterv2
    key: "000102030405060708090A0B0C0D0E0F"
```

To jest klucz **testowy**, wygenerowany do tego korpusu. Ramki 03, 04 i 06 zostały nim
zaszyfrowane przez `qds.make_encrypted_walkby()` — nie pochodzą z prawdziwego licznika
i nie ujawniają niczyjego klucza. Ramka 07 jest prawdziwa (ze zgłoszenia upstreamu),
ale jej klucza nikt poza właścicielem nie ma i nie jest do niczego potrzebny.

## Wstrzyknięcie

Jedna ramka na linię, publikować na topik RAW dodatku:

```bash
# tr -d '\r' jest celowe: plik przypięty jest do LF, ale gdy trafi tu przez
# synchronizację QNAP-a albo edytor windowsowy, ogon CR sprawia, że filtr
# wejściowy dodatku odrzuca ramkę jako nie-hex, bez śladu w logu.
tr -d '\r' < tcp_inject.txt | while read -r t; do
  mosquitto_pub -h <broker> -t 'wmbus/test/telegram' -m "$t"
  sleep 2
done
```

## Czego oczekiwać

Zmierzone na przypiętym `wmbusmeters` 3.0.0 — to nie są oczekiwania wyliczone
z naszego własnego parsera, tylko realny wynik dekodera przed filtrem i po nim:

| # | status klasyfikatora | bez filtra | z filtrem | co sprawdza |
|---|---|---|---|---|
| 01 | `QDS_NO_MFCT_BLOCK` | 1.387 | 1.387 | zwykłe rekordy CI=0x7A tego samego licznika — wartość odniesienia |
| 02 | `QDS_PLAINTEXT_OK` | 1.387 | 1.387 | blok jawny (bajt[4]=0x00), klucz niepotrzebny |
| 03 | `QDS_PLAINTEXT_OK` | **brak** | **1.387** | blok zaszyfrowany + klucz → deszyfracja, zgodność z 01/02 |
| 04 | `QDS_PLAINTEXT_OK` | brak | **2.350** | druga ramka, inny odczyt — widać, że wartość się rusza |
| 05 | `QDS_DECRYPT_FAILED` | brak | brak | zaszyfrowane **innym** kluczem → zgłoszony zły klucz, zero wartości |
| 06 | `QDS_ENCRYPTED_PAYLOAD` | brak | brak | licznik `60555886` bez klucza → prośba o zwykły klucz AES licznika |
| 07 | `QDS_DECRYPT_FAILED` | **15430.611** | **brak** | **regresja** — patrz niżej |
| 08 | `QDS_UNKNOWN_LAYOUT` | brak | brak | bajt[4]=0x17, ani 0x00 ani 0x35 — nieznana generacja |
| 09 | `QDS_UNKNOWN_LAYOUT` | brak | brak | `0DFF5F` z LVAR=0x0C zamiast 0x35 |
| 10 | `QDS_NO_MFCT_BLOCK` | 0.066 | 0.066 | kontrola: prawdziwa ramka BMETERS, ma przejść bez tknięcia |

Dwie linie, na które warto patrzeć:

- **07 to właściwy test.** Prawdziwa ramka ze zgłoszenia wmbusmeters #2025, w której
  `blob[9]` przypadkiem wynosi `0x13`. Niezałatany dekoder publikuje z niej
  `total_m3 = 15430.611` ze `status: OK` na liczniku pokazującym 1,387 m³ — mniej więcej
  raz na 8 h na licznik. Po filtrze ma zostać **samo `meter_datetime` 2026-07-08 06:41**.
  Jeśli kiedykolwiek zobaczysz tu liczbę, zabezpieczenie jest zepsute.
- **10 to kontrola negatywna.** Prawdziwa ramka hydrodigit
  (`tests/fixtures/hydrodigit/03264950.hex`) — reprezentuje ~29 liczników BMT, które tego
  bloku nie nadają. Ma dekodować dokładnie tak jak dziś i wyjść z filtra bajt w bajt
  taka sama.

Statusy widać w logu dodatku jako linie `[QDS] <id> <STATUS>: …`, z wersją i typem
licznika, polem CI, listą znalezionych rekordów DIF/VIF i powodem odrzucenia.

`expected.json` zawiera to samo maszynowo (linia, status, telegram, opis).

## Regeneracja

Ramki 03–06 i 08 są generowane, nie wpisane ręcznie. Odtworzyć je można przez
`qds.make_encrypted_walkby()` — sygnatura i semantyka w `rootfs/usr/bin/qds.py`.
Ramki 01, 02, 07 pochodzą ze zgłoszenia #2025, ramka 09 z korpusu testowego
wmbusmeters (`qcaloric`, przypadek `whe46x`), ramka 10 z fixture'ów tego repo.
