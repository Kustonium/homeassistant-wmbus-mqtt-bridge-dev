# Claude Handoff — sesja 2026-05-31

## Kontekst

Sesja dotyczyła dwóch potwierdzonych błędów logiki w bridge.sh:
1. **Race condition** przy równoległych zapisach plików TSV kandydatów.
2. **Brak automatycznego preview wartości** dla kandydatów w trybie czystego LISTEN/Discover.

---

## Wdrożone poprawki

### 1. Race condition zapisu TSV — `flock` + `mktemp` (commit `f1e369a`)

**Problem:** Pięć ścieżek kodu (primary LISTEN, parallel LISTEN, JSON update, RAW fallback, SEARCH) wywoływało `status_candidate_seen()` równolegle, każda robiąc niezabezpieczony read-modify-write na wspólnym pliku `.tmp`. Ostatni writer nadpisywał listę, usuwając wcześniej wykrytych kandydatów. Objaw: lista kandydatów znikała i zmieniała zawartość przy szybkim replay (interval=5s).

**Poprawka:**
- Nowy helper `_tsv_upsert(file, id, row)` z `flock -x 9` na `FILE.lock` i `mktemp` dla pliku tymczasowego.
- Cały read-modify-write (awk + printf + mv) wykonywany pod blokadą.
- Zastosowany do 5 plików TSV:

| Funkcja | Plik |
|---------|------|
| `status_candidate_seen` | `status_candidates.tsv` |
| `status_upsert_candidate_analysis` | `status_candidate_analysis.tsv` |
| `status_record_candidate_raw` | `status_candidate_raw.tsv` |
| `status_meter_seen` | `status_meters.tsv` |
| `_store_candidate_value` | `status_candidate_values.tsv` |

- Dodano `tests/test_candidate_race.sh` — 4 testy współbieżnych zapisów (wymaga Linux z `flock`).

### 2. Debounce `.reload_listen` — `_request_listen_reload` (commit `f1e369a`)

**Problem:** Przy stress teście z wieloma nowymi kandydatami równocześnie każdy nowy kandydat wywoływał `touch .reload_listen`, powodując serię restartów LISTEN co kilka sekund.

**Poprawka — `_request_listen_reload()`:**
- Gate file `${BASE}/.reload_listen_gate` z timestampem ostatniego reloadu.
- Jeśli minęło ≥ 10 s — natychmiastowy `touch .reload_listen`.
- Jeśli w oknie cooldown — jeden background `sleep <remaining>` z pending markerem.

**Atomowy pending marker (`mkdir`) (commit `f1e369a`, doprecyzowany w następnej sesji):**
- Stary kod: `[[ ! -f pending ]] && touch pending` — race condition (TOCTOU).
- Nowy kod: `mkdir "${pending}" 2>/dev/null` — atomowa operacja POSIX, tylko jeden writer wygrywa wyścig.
- Worker śpi tylko pozostały czas cooldownu (`remaining = 10 - elapsed`), nie pełne 10 s.

**Cleanup osieroconego pending (commit `f1e369a`):**
- Na starcie bridge.sh: `rm -rf "${BASE}/.reload_listen_pending"` — usuwa katalog-lock pozostawiony przez twardy stop podczas deferred sleep.

### 3. Parallel LISTEN zawsze uruchamiany (commit `6b91d2b`)

**Problem:** Supervisor parallel LISTEN startował tylko gdy `METERS_COUNT > 0 || listen_preview_count > 0`. W czystym trybie LISTEN/Discover bez skonfigurowanych liczników i bez plików preview — nie startował wcale. Gdy pierwszy kandydat tworzył `meter-preview-<id>` i wywoływał `_request_listen_reload()`, nie było żadnego supervisora obsługującego `.reload_listen`. Kandydaci zostawali na „dekoduję…" na zawsze.

**Poprawka:** Usunięto warunek `if/else` — `start_listen_instance` wywoływane bezwarunkowo. Zabezpieczenie przed podwójnym liczeniem kandydatów (`OFFICIAL_METERS_COUNT` guard) działa na poziomie `parse_listen_candidates()`, niezależnie od tego czy LISTEN startuje.

Usunięto martwą zmienną `METERS_COUNT` (SC2034) w commicie `386c0bb`.

### 4. Stany preview kandydatów — `status_candidate_preview_state.tsv` (commit `ca7a993`)

**Problem:** Brak rozróżnienia między trzema stanami preview:
- Kandydat czeka na pierwszy telegram po reloadzie LISTEN.
- JSON przyszedł, ale nie ma pola numerycznego (np. HCA, alarm).
- Brak odpowiedzi (jeszcze nie zaimplementowane).

Stary kod: `_store_candidate_value` zwracał cicho (`return 0`) gdy brak wartości → kandydat zostawał na „dekoduję…" w nieskończoność.

**Poprawka:**
- Nowy plik `status_candidate_preview_state.tsv`: `id | state | ts | note`.
- Nowy helper `_set_preview_state(id, state)` — używa `_tsv_upsert` (flock-safe).
- `ensure_candidate_autodecode()`: zapisuje `pending` przy tworzeniu `meter-preview-<id>`.
- `_store_candidate_value()`: zapisuje `decoded_value` lub `decoded_without_numeric_value`.
- `webui.py`: czyta nowy TSV, przekazuje `preview_state` per kandydat.
- `app.js`: renderuje `decoded_without_numeric_value` jako „brak wartości w telegramie" (szary).
- `i18n.py`: klucz `preview_no_value` dla en/pl/de/cs/sk.

### 5. Fix etykiet szyfrowania (commit `ca7a993`)

**Problem:** `unknown` był w liście `good` w `encBadge()` → renderowany jako zielony „Brak AES". To błąd — `unknown` oznacza „nie przeanalizowano", nie „brak AES".

**Poprawka w `app.js` (`encBadge()`):**

| Wartość `encryption` | Wyświetlana jako | Kolor |
|---------------------|-----------------|-------|
| `encrypted`, `aes_required`, `aes` | Wymaga AES | czerwony |
| `unknown` | Nieustalone (enc_unknown) | szary (muted) |
| `no_aes`, `not_encrypted`, `plain`, `unencrypted` | Brak AES | zielony |
| puste | `?` | szary |

---

## Wypchnięte commity (od najnowszego)

```
ca7a993  feat: candidate preview states + fix encryption badge for unknown
5000f77  diag: add [DIAG] trace logs for candidate preview lifecycle
386c0bb  fix(ci): remove dead variable METERS_COUNT (SC2034)
6b91d2b  fix: always start parallel LISTEN so preview works before first meter
b0ab628  fix(ci): replace unused loop var rep with _ to silence SC2034
f1e369a  fix: serialize candidate TSV updates and debounce listen reloads
```

---

## Zmienione pliki

| Plik | Zmiany |
|------|--------|
| `rootfs/usr/bin/bridge.sh` | `_tsv_upsert`, `_set_preview_state`, `_request_listen_reload` (flock+mktemp+debounce+mkdir), `ensure_candidate_autodecode` (stan pending + [DIAG]), `_store_candidate_value` (stany + [DIAG]), supervisor LISTEN ([DIAG]), `parse_listen_candidates` ([DIAG]), `start_listen_instance` bezwarunkowe, usunięto `METERS_COUNT`, `STATUS_CANDIDATE_PREVIEW_STATE_FILE` |
| `rootfs/usr/bin/webui.py` | `STATUS_CANDIDATE_PREVIEW_STATE_FILE`, odczyt nowego TSV, `preview_state` per kandydat |
| `rootfs/usr/bin/i18n.py` | `preview_no_value` dla en/pl/de/cs/sk |
| `rootfs/usr/share/wmbus-webui/assets/app.js` | `encBadge()` (unknown → muted), `previewCell` (stan `decoded_without_numeric_value`) |
| `tests/test_candidate_race.sh` | Nowy plik — 4 testy współbieżnych zapisów TSV |

---

## Testy automatyczne

- `tests/test_candidate_race.sh` — napisany, weryfikuje:
  - 20 ID × 3 równoległych writerów → 20 wierszy bez duplikatów
  - Monotonic growth: wcześniejsze ID nie znikają po dodaniu nowych
  - Ten sam ID zapisany 50× → dokładnie 1 wiersz
  - Stress: 200 rapidnych zapisów × 20 ID
- **Uwaga:** Wymaga Linuxa z `flock` (util-linux). Nie uruchamiany lokalnie (brak Docker/WSL).
- ShellCheck CI: przeszedł (po poprawce SC2034 `METERS_COUNT` i `for _`).

---

## Testy ręczne

### Stress test TSV race condition
- `wmbus-mqtt-replay.exe -interval 5` — 2 pełne przebiegi corpusu
- **Wynik:** Lista kandydatów stabilizuje się na 34 ID, rośnie monotonicznie, brak znikających rekordów, brak duplikatów.

### Smoke test preview
- `wmbus-mqtt-replay.exe -file preview_smoke_test.txt -interval 5 -once`
- 5 × qwaterv2 ID 52632878 + 5 × iwmtx5 ID 24360570
- **Wynik:** Preview działa automatycznie — wartości pojawiają się bez ręcznego dodawania liczników:
  - 52632878 qwaterv2 → 9.015 m³
  - 24360570 iwmtx5 → 29.458 m³

### Log [DIAG] — potwierdzony zapis wartości dla wielu kandydatów
```
52632878 qwaterv2 total_m3
67433753 qheatv2 total_kwh
32131245 fhkvdataiii current_hca
03264950 hydrodigit total_m3
67250945 qheatv2 total_kwh
21031894 evo868 consumption_at_history_1_m3
67899850 qheatv2 energy_delta_10_kwh
```

---

## Pozostałe logi diagnostyczne [DIAG]

Logi `[DIAG]` są **celowo pozostawione** w tej wersji do dalszej weryfikacji. Pokrywają:
- `ensure_candidate_autodecode`: tworzenie/brak zmiany pliku preview, driver, ścieżka
- `_request_listen_reload`: natychmiastowy/odroczony/suppressed reload
- Supervisor LISTEN: count `meter-preview-*` przed startem, wykrycie `.reload_listen`, stop/restart pipeline
- `parse_listen_candidates`: każda linia JSON z parallel LISTEN
- `_store_candidate_value`: id, value_key, value, zapis TSV lub powód pominięcia

---

## TODO — do dalszej pracy

### Priorytet wysoki
1. **Uruchomić strict corpus:** `01_strict_replay_all_validated.txt` — pełna weryfikacja poprawności po wszystkich zmianach lifecycle LISTEN.
2. **Usunąć lub schować [DIAG] za flagą debug** po zakończeniu testów regresyjnych. Rozważyć zmienną `WMBUS_DEBUG=true` lub poziom loglevel.

### Priorytet średni
3. **Stan `no_decode_result`:** Zaimplementować dla kandydatów, gdzie `meter-preview-<id>` istnieje, ale po kilku odebranych telegramach nadal brak JSON z parallel LISTEN (wmbusmeters nie dekoduje). Wymaga licznika lub timeout per ID — **nie implementować pochopnie**, najpierw zbadać które konkretne ID nadal wiszą po strict corpus test.
4. **Weryfikacja `fhkvdataiii` i innych HCA:** Kandydaci z `decoded_without_numeric_value` — sprawdzić jakie pola wmbusmeters faktycznie emituje i czy heurystyka wyboru wartości wymaga rozszerzenia.

### Priorytet niski
5. **Usunąć `listen_preview_count()`** — funkcja zdefiniowana w bridge.sh, ale już nigdzie niewoływana po usunięciu warunku `start_listen_instance`. Nie powoduje błędów (ShellCheck nie ostrzega o nieużywanych funkcjach), ale to martwy kod.

---

## Modularizacja `bridge.sh` — status 2026-06-03

Ostatnie potwierdzone etapy modularizacji:

- Stage 1: `00-logging.sh`, `01-utils.sh` — commit `70fe75f`, wypchnięty.
- Stage 2: `02-config.sh` — commit `2632aed`, wypchnięty.
- Stage 3: `03-tsv.sh` — commit `f2c89f8`, wypchnięty.
- Stage 4: `08-discovery-helpers.sh` — commit `2b844f0`, wypchnięty.
- Stage 5: `05-raw.sh` — commit `d61b3bc`, wypchnięty.
- Stage 6: `06-candidates.sh` — przygotowany lokalnie. Przeniesione funkcje:
  `_set_preview_state`, `_request_listen_reload`,
  `status_upsert_candidate_analysis`, `candidate_autodecode_file`,
  `candidate_type_requires_aes`, `ensure_candidate_autodecode`,
  `sync_candidate_autodecode_files`, `prune_official_meter_previews`,
  `status_record_candidate_raw`, `status_analyze_candidate_from_text`,
  `status_mark_search_decoded_no_aes`, `status_candidate_seen`.

Stage 6 jest refaktorem behavior-preserving:

- `bridge.sh` sourcuje `06-candidates.sh` po `05-raw.sh` i przed `08-discovery-helpers.sh`.
- Ciała wszystkich 12 przeniesionych funkcji porównane z `HEAD` — zero różnic.
- Dodano tylko dwie dyrektywy `# shellcheck disable=SC2034` poza ciałami funkcji, dla warningów wynikających z separacji modułu.
- Nie zmieniono preview state machine, `.reload_listen`, autodecode, TSV schema, MQTT topiców, WebUI ani konfiguracji `wmbusmeters`.

Walidacja Stage 6 na kopii LF w WSL:

```
bash -n bridge.sh/run.sh/entrypoint.sh/test_candidate_race.sh/bridge-lib/*.sh  OK
body diff 12 candidate functions vs HEAD                                  OK
shellcheck -s bash -S warning -x                                           OK
tests/test_candidate_race.sh                                               7 passed, 0 failed
tests/test_value_selection.sh                                              13 passed, 0 failed
preview state machine mini-test                                            OK
listen reload debounce mini-test                                           OK
git diff --check                                                           OK
```

---

## Walidacja lokalna w WSL

WSL jest dostępny i nadaje się do walidacji bash/testów:

```
Ubuntu WSL2
bash: /usr/bin/bash
flock: /usr/bin/flock
jq: /snap/bin/jq
shellcheck: /snap/bin/shellcheck
awk: /usr/bin/awk
mktemp: /usr/bin/mktemp
```

Windowsowy working tree ma CRLF w części plików, więc nie uruchamiać `bash -n`
bezpośrednio na plikach z `/mnt/c/...`. Do walidacji używać tymczasowego
checkoutu LF z `git archive HEAD`.

Ważne dla Codex/Codex Desktop: komendy Windows -> WSL uruchamiać przez
`cmd.exe /d /s /c`, nie przez PowerShell. W tym repo PowerShell częściej
powodował problemy z cytowaniem, zmiennymi i diagnostyką CRLF, a `cmd.exe`
okazał się stabilniejszą ścieżką do `wsl bash -lc`.

Praktyczna komenda z Windows przez `cmd.exe -> WSL`:

```cmd
cmd.exe /d /s /c "wsl -d Ubuntu -- bash -lc ""set -euo pipefail; rm -rf ~/hawmq-validate; mkdir -p ~/hawmq-validate; cd /mnt/c/Users/foszt/Documents/GitHub/homeassistant-wmbus-mqtt-bridge-dev; git archive HEAD | tar -x -C ~/hawmq-validate; cd ~/hawmq-validate; bash -n rootfs/usr/bin/bridge.sh; bash -n rootfs/usr/bin/run.sh; bash -n docker/entrypoint.sh; bash -n tests/test_candidate_race.sh; shellcheck -s bash docker/entrypoint.sh rootfs/usr/bin/bridge.sh rootfs/usr/bin/run.sh tests/test_candidate_race.sh; bash tests/test_candidate_race.sh; cd /mnt/c/Users/foszt/Documents/GitHub/homeassistant-wmbus-mqtt-bridge-dev; git diff --check; git diff --stat; git status --short --untracked-files=all"""
```

Uzasadnienie `shellcheck -s bash`: `rootfs/usr/bin/run.sh` ma shebang
`#!/usr/bin/with-contenv bashio`, którego ShellCheck nie rozpoznaje bez jawnego
trybu powłoki (`SC1008`). Z `-s bash` ShellCheck przechodzi czysto.

Ostatni potwierdzony wynik tej komendy:

```
bash -n rootfs/usr/bin/bridge.sh        OK
bash -n rootfs/usr/bin/run.sh           OK
bash -n docker/entrypoint.sh            OK
bash -n tests/test_candidate_race.sh    OK
shellcheck -s bash                      OK
tests/test_candidate_race.sh            7 passed, 0 failed
git diff --check                        OK
git diff --stat                         brak zmian
git status                              ?? AGENTS.md
```

---

## Prompt startowy do nowej sesji

```
Kontynuujemy pracę nad homeassistant-wmbus-mqtt-bridge-dev (branch: main).

Ostatnia sesja wdrożyła następujące poprawki (szczegóły w docs/CLAUDE_HANDOFF.md):
- flock + mktemp dla wszystkich zapisów TSV (_tsv_upsert)
- debounce .reload_listen z atomowym mkdir jako pending marker
- cleanup osieroconego .reload_listen_pending na starcie
- parallel LISTEN startuje zawsze (bez warunku na liczniki)
- status_candidate_preview_state.tsv z trzema stanami preview
- fix encBadge(): unknown → szary "Nieustalone"
- logi [DIAG] pozostawione do weryfikacji

Do zrobienia w tej sesji:
1. Uruchomić 01_strict_replay_all_validated.txt i zweryfikować wyniki.
2. Na podstawie wyników zdecydować, które ID nadal wiszą na "dekoduję..." i dlaczego.
3. Jeśli wszystko OK — usunąć lub schować logi [DIAG] za flagą debug.
4. Rozważyć stan no_decode_result dla kandydatów bez odpowiedzi po kilku próbach.

Zasady projektu:
- Przed każdym push: bash -n na wszystkich .sh, ShellCheck gdy dostępny.
- Używać POSIX paths (/f/QNAP/...) w Git Bash, nie Windows paths (F:\...).
- find z -print0 | xargs -0 do iteracji po plikach ze spacjami.
- Nie usuwać logów [DIAG] przed zakończeniem testów regresyjnych.
```
