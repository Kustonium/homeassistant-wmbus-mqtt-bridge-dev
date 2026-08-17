# Fixture'y: inwentarz sprzętu z żywej instancji HA

Zrzuty `GET /hardware/info` (Supervisor API) zebrane **2026-08-16 na działającej instancji
HAOS**, przy kolejnych wpięciach i wypięciach realnych urządzeń. **Żadne z tych danych nie
są syntetyczne** — to prawdziwy sprzęt na prawdziwym systemie, wpinany po kolei, część
w ślepej próbie (bez podania, co to jest), właśnie po to, żeby wyłapać przypadki, których
nikt by nie wymyślił przy biurku. Służą do testowania logiki
pickera portów zakładki M-Bus (`docs/ARCHITECTURE.md` §5.4) **bez sprzętu**.

## Anonimizacja

Repozytorium jest publiczne, więc numery seryjne i MAC-i zostały podmienione
(`SERIAL000…`, `AA:BB:CC:00:00:0N`) — **spójnie w obrębie pliku i między plikami**.
Zachowane bez zmian: VID:PID, łańcuchy producenta/modelu, klasy interfejsów, `ID_PATH`,
`DEVLINKS`, obecność lub brak numeru seryjnego oraz **kolizje** ścieżek `by-id`. Czyli
wszystko, o co logika pyta. Skrypt anonimizujący leży obok (`make_fixtures.py`).

Pominięte: sekcja `drives` i podsystemy inne niż `tty` / `usb` / `block`.

## Co który plik udowadnia

| Plik | Scenariusz | Asercja do napisania |
|---|---|---|
| `01-baseline` | SkyConnect + CH340 + 4× `ttyS` | picker zwraca 6 pozycji; SkyConnect oznaczony jako zajęty przez integrację |
| `02-rtlsdr` | RTL-SDR wpięty | lista `tty` **identyczna** jak w `01`; osobna ścieżka `usb` wykrywa `0bda:2838` |
| `03-esp-single` | jedna płytka ESP32-S3 | powstaje `ttyACM0`, `by-id` unikalne (serial = MAC), ostrzeżenie „to Twój mostek ESP" |
| `04-esp-two` | dwie płytki ESP | identyczne VID:PID **i** łańcuch produktu; rozpoznanie kończy się na „jakaś płytka ESP" |
| `05-esp-renumbered` | po przepięciu | `ttyACM0` wskazuje **inną** płytkę niż w `04` → `device_identity_check` musi zwrócić `changed` |
| `06-non-serial` | pendrive + czytnik CCID | filtr `subsystem == "tty"` odsiewa oba; lista portów bez zmian |
| `07-dvbt-tuner` | tuner ITE `048d:9135` | brak `ID_MODEL` w bazie udev → komunikat musi umieć pokazać samo VID:PID; żaden węzeł nie powstał |
| `08-pl2303` | PL2303 bez numeru seryjnego | klasa `:ff0000:` **tak samo jak tuner**, a jednak jest `tty` → klasa interfejsu NIE jest filtrem |
| `09-ch340-collision` | dwa **identyczne** CH340 (dwa te same kable) | **ta sama** ścieżka `by-id` dla dwóch urządzeń → `stable_path_for()` musi zejść na `by-path` i zwrócić powód `by_id_ambiguous` |
| `10-ch340-no-collision` | dwa CH340 **różnego pochodzenia** (kabel + ESP8266) | ten sam VID:PID i brak seriali u obu, ale **różne łańcuchy produktu** (`USB_Serial` vs `USB2.0-Ser_`) → `by-id` różne, `by_id_ambiguous` **NIE może się odpalić**. Przypadek negatywny: chroni przed logiką porównującą pary VID:PID zamiast konkretnych łańcuchów `by_id` |

## Dlaczego to jest warte trzymania

Dwie tezy wpisane do szkicu jako pewniki padły dopiero na tych danych:

1. „`by-id` jest zawsze bezpieczniejsze od surowej ścieżki" — obalone przez `09`;
2. „klasa interfejsu USB odróżnia port od nie-portu" — obalone przez `08` w zestawieniu z `07`;
3. „dwa CH340 zawsze kolidują" — zawężone przez `10`: kolizja wymaga **kompletu** trzech
   warunków (ten sam VID:PID, ten sam łańcuch produktu, brak seriali u obu).

Para `09` + `10` jest tu najcenniejsza: ten sam typ układu, ta sama liczba urządzeń, a jeden
przypadek ma kolidować i drugi nie. Test przechodzący tylko na `09` może triggerować za
szeroko i nikt tego nie zauważy.

Obie brzmiały sensownie i zgadzały się z wcześniejszymi obserwacjami. Fixture'y istnieją po
to, żeby przy pisaniu kodu nie trzeba było powtarzać tamtej sesji ze sprzętem w ręku.

**Czego te dane NIE pokrywają:** niczego po stronie magistrali. Brak odpowiedzi z adresu,
kolizje adresów pierwotnych, zachowanie prawdziwego konwertera M-Bus — na to trzeba sprzętu,
którego nie ma. Fixture'y kończą się na wyborze portu.
