# Handoff — sesja 2026-06-04 (preview reload-churn)

> Uwaga dla wszystkich agentów (Claude, Codex, BMAD): w tym repo kod pisze
> kilka różnych agentów. Modularizację monolitu `bridge.sh` na `bridge-lib/*.sh`
> zrobił Codex+BMAD; część fixów robi Claude. Zanim zmienisz ścieżkę
> kandydatów/preview/LISTEN — przeczytaj ten rozdział, bo opisuje subtelny
> regres i konwencję, której nie wolno złamać.

## Naprawiony (powiązany): pełna NAZWA producenta przy liczniku dodanym w trybie skonfigurowanym

Status: **NAPRAWIONY** 2026-06-04 — `bridge-lib/05-raw.sh`. Dodano
`mfct_name_from_code()` (tabela kod→nazwa, potwierdzone: BMT→BMETERS,
NES→NORA ELK MALZ SAN ve TIC, SAP→Diehl Metering, QDS→Qundis, TCH→Techem).
Ścieżka RAW wpisuje teraz pełną formę `(CODE) Vendor` zamiast gołego kodu, więc
kompaktor webui pokazuje `CODE · Vendor` także dla liczników odkrytych w trybie
DECODE (gdzie blok tekstowy LISTEN jest martwy). Nieznane kody → goły kod (bez
regresji); guard fill-only-when-empty-or-bare uzdrawia istniejący goły kod i nie
psuje pełnej nazwy z LISTEN. Walidacja: bash -n + shellcheck OK, test
funkcjonalny (goły BMT → (BMT) BMETERS; nieznany → goły kod), 7/7 + 13/13.
Rozszerzać tabelę o kolejnych vendorów gdy się pojawią. Opis poniżej jako
kontekst.

**Objaw (potwierdzony na żywo):**
- Licznik dodany gdy LISTEN był „print all" (brak/mało preview) → **pełna nazwa**,
  np. `03528308` → `BMT · BMETERS`, `00089907` → `NES · NORA ELK MALZ SAN ve TIC`.
- Kolejny licznik dodany PÓŹNIEJ, gdy inny jest już skonfigurowany → **tylko
  skrócony 3-literowy kod**, np. `03528557` → `BMT` (zamiast `BMT · BMETERS`).
- Bez żadnego licznika → cała lista ma pełne nazwy.

**Przyczyna (ta sama martwa strefa):** pełny tekst producenta
`(BMT) BMETERS, ...` pochodzi WYŁĄCZNIE z bloku tekstowego LISTEN
(`manufacturer: ...`), który pojawia się tylko gdy wmbusmeters jest w trybie
„Printing id:s of all telegrams heard!" (0 liczników w danej instancji). Gdy
liczniki są skonfigurowane, parallel LISTEN ma pliki preview i wychodzi z tego
trybu → blok tekstowy nie leci → `candidate_update_manufacturer_text`
(`11-listen.sh`) nie dostaje pełnej nazwy. Fix wykrywania (`999cbdf`,
`05-raw.sh`) sprawił, że kandydat się POJAWIA, ale ścieżka RAW wpisuje tylko
**3-literowy kod** z M-pola (`candidate_fill_manufacturer_code`), nie pełną
nazwę. Stąd skrócony `BMT`.

**Kierunki naprawy (do rozważenia, bez 3. instancji):**
1. **Tabela kod→nazwa** (FLAG/EN 13757) w ścieżce RAW lub webui: `BMT→BMETERS`,
   `NES→NORA ELK MALZ SAN ve TIC`, `SAP→Diehl Metering`, `QDS→Qundis`,
   `TCH→Techem`, `EWT→...` itd. Wtedy pełna nazwa niezależnie od LISTEN. Koszt:
   utrzymanie tabeli (można wygenerować z wmbusmeters `manufacturers`).
2. Trwale zachować pełną nazwę raz złapaną w fazie „print all" (już działa dla
   liczników dodanych wtedy) — ale dla dodanych później brak źródła.
3. Zaakceptować skrócony kod dla liczników dodanych w trybie skonfigurowanym
   (jest poprawny, tylko mniej ładny).

Powiązane: to samo zjawisko co „głuche wykrywanie" niżej — oba wynikają z braku
bloku tekstowego LISTEN w trybie z licznikiem. Discovery + decode już naprawione
(`999cbdf`); zostaje tylko pełna NAZWA.

---

## Naprawiony bug: głuche wykrywanie kandydatów przy skonfigurowanym liczniku

Status: **NAPRAWIONY** 2026-06-04 — w `bridge-lib/05-raw.sh`
(`status_raw_candidate_seen`). Gdy `OFFICIAL_METERS_COUNT > 0`, ścieżka RAW
rejestruje teraz **wszystkich** producentów (nie tylko Diehl/SAP), bo LISTEN ich
nie wykrywa (martwa strefa „print all"). Tryb bez liczników bez zmian. Hardcode
`izarv2` dla typu 0x07 zawężony do Diehl/SAP (mfct 0x304C), żeby nie mylić
wodnego QDS/BMETERS z izarv2. Walidacja: bash -n + shellcheck OK, test
funkcjonalny (bez licznika tylko Diehl; z licznikiem wszyscy, QDS=auto nie
izarv2), test_candidate_race 7/7, test_value_selection 13/13. Poniższy opis
zostawiony jako kontekst diagnostyczny.

**Objaw:**
- **Bez** skonfigurowanego licznika (`OFFICIAL_METERS_COUNT == 0`): addon wykrywa
  i dekoduje **całą listę** kandydatów z replay (qwaterv2 `53158939`/`52632878`,
  EWT `65000160`, DME `87181227`, izarv2 `215F908A`/`2156B4C2`, itd.).
- **Z** dodanym licznikiem (`OFFICIAL_METERS_COUNT > 0`): addon jest „głuchy" na
  resztę — pokazują się **tylko** kandydaci, którzy **już mieli plik
  `meter-preview-<id>`** albo wchodzą **specjalną ścieżką RAW** (Diehl/SAP IZAR
  `215F908A`/`2156B4C2`). **Nowi** kandydaci (np. qwaterv2) **nie pojawiają się
  wcale**.

**Hipoteza przyczyny (ta sama martwa strefa co przy producencie):**
- Gdy `OFFICIAL_METERS_COUNT == 0`: kandydatów wykrywa **inline parser w
  `run_once`** (`bridge.sh`), bo główny potok jest w trybie LISTEN „print all".
- Gdy `OFFICIAL_METERS_COUNT > 0`: ten inline parser jest **zablokowany**
  (`if [[ "${OFFICIAL_METERS_COUNT}" -eq 0 ... ]]`), a wykrywanie przenosi się na
  **parallel LISTEN**. Ale parallel LISTEN, gdy ma już pliki `meter-preview-*`,
  ładuje je jako liczniki (`number of meters: N>0`) i **wychodzi z trybu
  „Printing id:s of all telegrams heard!"** → dla telegramów niepasujących do
  żadnego preview wmbusmeters drukuje tylko `(wmbus) telegram from TODO ignored
  by all configured meters!` **bez** bloku analizy → `_process_listen_text_block`
  nigdy nie dostaje nowego kandydata → brak `emit_snippet_if_new` → kandydat nie
  powstaje. Diehl/SAP pojawia się tylko dzięki `status_raw_candidate_seen`
  (`05-raw.sh`), który łapie go z M-pola niezależnie od LISTEN.

**Dowód:** zrzuty użytkownika + logi 02:59 (bez licznika: 7 kandydatów dekoduje)
vs tryb skonfigurowany (tylko 2 izary). To NIE jest churn ani crash — te są już
naprawione (patrz niżej). To osobny, wcześniejszy problem architektoniczny.

**Czego NIE robić:** nie wracać do `14-detect.sh` (3. instancja) — była cofnięta,
bo kolidowała z dekodowaniem preview (commit revert `2fda975`).

**Kierunki naprawy do rozważenia (bez 3. instancji):**
1. Odblokować inline parser kandydatów w `run_once` **także** gdy są liczniki —
   główny potok w DECODE nie drukuje jednak bloku „Received telegram from", więc
   to samo nie wystarczy; trzeba by drugiego źródła tekstu.
2. Zmusić parallel LISTEN, by **zawsze** był w trybie „print all" (0 liczników),
   a dekodowanie preview rozwiązać inaczej — ale to rusza potwierdzony-działający
   obszar preview, ostrożnie.
3. Rozszerzyć ścieżkę RAW (`status_raw_candidate_seen`) tak, by rejestrowała
   **każdy** nowy ID z M-pola jako kandydata (nie tylko Diehl/SAP), niezależnie od
   LISTEN. Wtedy wykrywanie nie zależy od trybu „print all". Ryzyko: trzeba
   zachować poprawny driver/type (LISTEN-over-RAW priorytet FU-008) i nie
   psuć liczników odbioru.

**Najpierw zbadać:** czy w trybie skonfigurowanym parallel LISTEN ma
`number of meters: 0` (preview nie ładują się — wtedy print-all i bug jest gdzie
indziej) czy `N>0` (preview ładują się → potwierdzona martwa strefa). To
rozstrzyga między kierunkiem 2 a 3. Potrzebny log `loglevel=debug` z trybu
z licznikiem, linia `(config) number of meters:` dla pipeline'u parallel LISTEN.

## Potwierdzony bug: reload-churn previews przy skonfigurowanych licznikach

**Objaw:** wartości preview kandydatów wiszą na „dekoduję…", gdy w
`options.json` jest ≥1 oficjalny licznik. Po usunięciu liczników — działają.
Świeża instalacja działa. To **mylnie** wygląda na problem modularizacji,
mojej instancji `14-detect.sh`, albo wersji wmbusmeters.

**Co to NIE było (wykluczone dowodami):**
- Nie modularizacja: `run_once`, `parse_listen_candidates`,
  `_store_candidate_value`, `ensure_candidate_autodecode` są **byte-identyczne**
  z monolitem `503655b` (sprawdzone `diff` ciał funkcji).
- Nie `14-detect.sh`: użytkownik odtworzył wersję sprzed niej i bug został →
  instancja cofnięta (commit revert). **Nie dodawać jej ponownie** bez
  rozwiązania problemu manufacturera w inny sposób (bez 3. instancji).
- Nie wmbusmeters 2.0.0: ta sama binarka cały czas (build edge).

**Prawdziwa przyczyna (commit `db2dfcc`, 2026-05-30, autor repo):** dodał
`status_candidate_seen_from_json()` i jego wywołanie w gałęzi JSON
`parse_listen_candidates`, gated `OFFICIAL_METERS_COUNT > 0`. Funkcja relabeluje
driver kandydata z JSON (`auto` → `izarv2`), co przez
`status_candidate_seen` → `ensure_candidate_autodecode` przepisuje
`meter-preview-<id>` i woła `_request_listen_reload`. Skutek: równoległy LISTEN
jest **zabijany i restartowany na każdym telegramie** (`LISTEN supervisor:
.reload_listen detected, killing pid=...`) → pipeline nie zdąża ustabilizować
dekodowania. Debug log użytkownika potwierdził churn ORAZ że po ustabilizowaniu
drivera previews jednak dekodują (`unchanged, no reload triggered`,
`_store_candidate_value ... value=430.142`).

**Fix (ta sesja):** `status_candidate_seen` dostaje 6. argument `reload`
(domyślnie `true` — wszyscy obecni wołający z ścieżki text/RAW bez zmian).
Ścieżka decoded-JSON (`status_candidate_seen_from_json`) przekazuje
`reload=false`: driver dalej odświeża się w pliku preview (na następny naturalny
restart), ale **bez** natychmiastowego reloadu → koniec churnu. Zmiana tylko w
`bridge-lib/06-candidates.sh` i `bridge-lib/11-listen.sh`.

**KONWENCJA do utrzymania:** wywołania `status_candidate_seen` z ścieżki
dekodowania JSON (gdzie kandydat już produkuje JSON, więc preview działa) MUSZĄ
używać `reload=false`. Reload zostawić tylko dla ścieżki text/RAW, gdzie nowy
plik preview faktycznie musi być podchwycony, żeby zacząć dekodować.

**Walidacja tej sesji (kopia LF w WSL):**
- `bash -n` 06/11/bridge.sh — OK; `shellcheck -s bash -S warning -x bridge.sh` — OK
- test funkcjonalny churn: text-path reloaduje (≥2), JSON-path reload=0,
  driver w pliku zaktualizowany, stabilne przy powtórce
- `tests/test_candidate_race.sh` 7/7, `tests/test_value_selection.sh` 13/13

**Otwarte:** osobny temat — pełna nazwa producenta dla SKONFIGUROWANEGO licznika
w trybie DECODE (martwa strefa: pełny tekst manufacturer leci tylko z listen-mode
„print all"). Instancja `14-detect.sh` to rozwiązywała, ale kolidowała (cofnięta).
Kierunki bez 3. instancji: tabela kod→nazwa w ścieżce RAW, albo trwałe zachowanie
nazwy złapanej w fazie listen.

---

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
- Stage 6: `06-candidates.sh` — commit `0135bd0`, wypchnięty. Przeniesione funkcje:
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

- Stage 7: `04-status.sh` — przygotowany lokalnie. Przeniesione funkcje:
  `status_add_event`, `status_record_seen`, `status_seen_stats`,
  `status_read_raw_count`, `status_read_last_raw_seen`,
  `status_store_raw_seen`, `status_store_recent_raw`,
  `status_find_recent_raw_for_id`, `write_status_json`,
  `status_mark_discovery_published`.

Stage 7 jest refaktorem behavior-preserving:

- `bridge.sh` sourcuje `04-status.sh` po `03-tsv.sh` i przed `05-raw.sh`.
- Ciała wszystkich 10 przeniesionych funkcji porównane z `HEAD` — zero różnic.
- Dodano tylko wąskie dyrektywy `# shellcheck disable=SC2034` przy globalach, które po ekstrakcji `write_status_json` są zapisywane w `bridge.sh`, a czytane w `04-status.sh`.
- Nie zmieniono status JSON schema, runtime status files, rate counters, event TSV, seen TSV, raw recent buffer, MQTT topiców, WebUI ani wrapperów.

Walidacja Stage 7 na kopii LF w WSL:

```
bash -n bridge.sh/run.sh/entrypoint.sh/test_candidate_race.sh/bridge-lib/*.sh  OK
body diff 10 status functions vs HEAD                                     OK
shellcheck -s bash -S warning -x                                           OK
tests/test_candidate_race.sh                                               7 passed, 0 failed
tests/test_value_selection.sh                                              13 passed, 0 failed
status json smoke test                                                     OK
```

- Stage 8: `07-meters.sh` — przygotowany lokalnie. Przeniesione funkcje:
  `_select_primary_meter_value`, `status_meter_seen`, `refresh_meter_files`.

Stage 8 jest refaktorem behavior-preserving:

- `bridge.sh` sourcuje `07-meters.sh` po `06-candidates.sh` i przed `08-discovery-helpers.sh`.
- Ciała wszystkich 3 przeniesionych funkcji porównane z `HEAD` — zero różnic.
- Dodano jedną dyrektywę `# shellcheck disable=SC2034` przed `refresh_meter_files`, bo funkcja zapisuje globale używane przez inne ścieżki runtime po modularizacji.
- `tests/test_value_selection.sh` został dostosowany do modułu: najpierw czyta `_select_primary_meter_value` z `bridge-lib/07-meters.sh`, z fallbackiem do `bridge.sh`.
- Nie zmieniono wyboru wartości licznika, `status_meters.tsv`, generowania `wmbusmeters.d/meter-*`, SEARCH fallbacku, MQTT topiców, WebUI ani wrapperów.

Walidacja Stage 8 na kopii LF w WSL:

```
bash -n bridge.sh/run.sh/entrypoint.sh/test_candidate_race.sh/bridge-lib/*.sh  OK
body diff 3 meter functions vs HEAD                                      OK
shellcheck -s bash -S warning -x                                           OK
tests/test_candidate_race.sh                                               7 passed, 0 failed
tests/test_value_selection.sh                                              13 passed, 0 failed
```

- Stage 9: `10-search.sh` — przygotowany lokalnie. Przeniesione deklaracje:
  `SEARCH_FIRST_VALUE`, `SEARCH_REPORTED_EXPECTED`, `SEARCH_REPORTED_DELTA`.
  Przeniesione funkcje: `search_cached_count`, `write_search_status`,
  `search_field_is_candidate`, `emit_search_payload`,
  `search_type_is_water_candidate`, `search_cache_candidate`,
  `create_search_meter_files_from_cache`, `process_search_json`,
  `search_record_match`.

Stage 9 jest refaktorem behavior-preserving:

- `bridge.sh` sourcuje `10-search.sh` po `08-discovery-helpers.sh`.
- Scalar init SEARCH pozostaje w `bridge.sh`, w tym `SEARCH_EXPECTED_VALUE_M3`,
  `SEARCH_TOLERANCE_M3`, `SEARCH_MIN_DELTA_M3`,
  `SEARCH_USING_TEMP_METERS`, `OFFICIAL_METERS_COUNT` i liczniki/statusy SEARCH.
- `write_search_status "auto" "bridge_starting"` pozostaje w `bridge.sh` jako init runtime.
- Ciała wszystkich 9 przeniesionych funkcji porównane z `HEAD` — zero różnic.
- Dodano tylko wąskie dyrektywy `# shellcheck disable=SC2034` przy scalarach SEARCH, które po ekstrakcji są zapisane w `bridge.sh`, a czytane/aktualizowane w `10-search.sh`.
- Nie zmieniono SEARCH status schema, `search_candidates.tsv`, `search_matches.tsv`, publikacji `search_topic`, heurystyki water candidate, SEARCH temp meter fallbacku, MQTT topiców, WebUI ani wrapperów.

Walidacja Stage 9 na kopii LF w WSL:

```
bash -n bridge.sh/run.sh/entrypoint.sh/test_candidate_race.sh/bridge-lib/*.sh  OK
body diff 9 search functions vs HEAD                                     OK
SEARCH declare -A moved                                                   OK
shellcheck -s bash -S warning -x                                           OK
tests/test_candidate_race.sh                                               7 passed, 0 failed
tests/test_value_selection.sh                                              13 passed, 0 failed
search status smoke test                                                   OK
```

- Stage 10: `09-discovery.sh` — przygotowany lokalnie. Przeniesione deklaracje:
  `DISCOVERY_SENT_FIELD`, `DISCOVERY_CLEANED_LEGACY`,
  `SEARCH_DISCOVERY_CLEARED_FIELD`. Przeniesione funkcje:
  `clean_legacy_totalm3`, `emit_discovery_from_json`,
  `is_search_temp_json`, `clear_search_discovery_from_json`.

Stage 10 jest refaktorem behavior-preserving:

- `bridge.sh` sourcuje `09-discovery.sh` po `08-discovery-helpers.sh` i przed `10-search.sh`.
- Ciała wszystkich 4 przeniesionych funkcji porównane z `HEAD` — zero różnic.
- Tablice asocjacyjne Discovery są inicjalizowane w module na top-level, po source do głównego shella.
- Nie zmieniono Home Assistant MQTT Discovery payloadów, `unique_id`,
  `object_id`, `state_topic`, legacy cleanup, SEARCH discovery cleanup, MQTT topiców, WebUI ani wrapperów.
- Uwaga walidacyjna: `normalize_meter_id` jest w `05-raw.sh`, więc izolowane harnessy Discovery muszą sourcować `05-raw.sh` przed `09-discovery.sh`.

Walidacja Stage 10 na kopii LF w WSL:

```
bash -n bridge.sh/run.sh/entrypoint.sh/test_candidate_race.sh/bridge-lib/*.sh  OK
body diff 4 discovery functions vs HEAD                                  OK
Discovery declare -A moved                                                OK
shellcheck -s bash -S warning -x                                           OK
tests/test_candidate_race.sh                                               7 passed, 0 failed
tests/test_value_selection.sh                                              13 passed, 0 failed
Discovery payload spot-check                                               OK
```

---

## Stage 11 - LISTEN + lifecycle extraction

Stage 11 przenosi logike parallel LISTEN do modulu:

```
rootfs/usr/bin/bridge-lib/11-listen.sh
```

Przeniesione definicje:

- `emit_snippet_if_new`
- `_store_candidate_value`
- `status_candidate_seen_from_json`
- `_process_listen_text_block`
- `parse_listen_candidates`
- `LISTEN_PID=""`
- `listen_preview_count`
- `start_listen_instance`
- `stop_listen_instance`

Celowo pozostawione w `bridge.sh`:

- `SNIPPET_STATE="${BASE}/seen_ids.txt"`
- `touch "${SNIPPET_STATE}"`
- `trap stop_listen_instance EXIT TERM INT`

Powod: moduly sa sourcowane bardzo wczesnie, przed inicjalizacja `BASE`, wiec
`SNIPPET_STATE` i `touch` nie moga wejsc do modulu bez zmiany kolejnosci
startowej albo dodania top-level side effectu. `trap` zgodnie ze specyfikacja
pozostaje w `bridge.sh`; funkcja `stop_listen_instance` jest juz dostepna,
bo `11-listen.sh` jest sourcowany przed rejestracja trap.

Wazne inwarianty zachowane w Stage 11:

- `write_status_json() { :; }` pozostaje wewnatrz `parse_listen_candidates`.
- `LISTEN_PID` jest globalny, nie `local`.
- `start_listen_instance` nadal jest idempotentne przez `kill -0 "${LISTEN_PID}"`.
- `stop_listen_instance` nadal zabija supervisor i dzieci pipeline.
- `run_once` oraz `wait_for_mqtt` nadal sa w `bridge.sh` i czekaja na Stage 12.

---

## Stage 12 - pipeline helper extraction

Stage 12 przenosi zachowawczo tylko pomocniki pipeline do modulu:

```
rootfs/usr/bin/bridge-lib/12-pipeline.sh
```

Przeniesione definicje:

- `mqtt_pub`
- `wait_for_mqtt`

Celowo pozostawione w `bridge.sh`:

- `run_once`
- `MQTT_WAIT_RETRIES="${MQTT_WAIT_RETRIES:-30}"`
- `MQTT_WAIT_DELAY="${MQTT_WAIT_DELAY:-2}"`

Decyzja: `run_once` nie zostal przeniesiony w Stage 12. Dokumentacja oznacza go
jako opcjonalny i najwyzszego ryzyka, a uzytkownik zglaszal, ze widzi bledy do
poprawienia po refaktorze. Zostawienie `run_once` w `bridge.sh` zmniejsza
ryzyko w trakcie mechanicznego podzialu.

Wazne inwarianty zachowane w Stage 12:

- `mqtt_pub` pozostaje wywolywane lazy przez Discovery i SEARCH po zaladowaniu
  `12-pipeline.sh`.
- `wait_for_mqtt` czyta `MQTT_WAIT_RETRIES` i `MQTT_WAIT_DELAY` dopiero przy
  wywolaniu w restart loop.
- `run_once` nadal zawiera glowne potoki `mosquitto_sub | wmbusmeters | while read`.

---

## Stage 13 - ESP subscriber extraction

Stage 13 przenosi background subscribery ESP do modulu:

```
rootfs/usr/bin/bridge-lib/13-esp.sh
```

Dodana funkcja:

- `start_esp_subscribers`

Przeniesiony blok:

- subscriber `wmbus/+/diag/summary` zapisujacy `status_esp_diag.json`
- tracker urzadzen ESP na podstawie `RAW_TOPIC` i `status_esp_telegram_devices.tsv`
- subscriber `wmbus/+/diag` oraz `wmbus/+/diag/#` zapisujacy eventy,
  sugestie i boot statusy ESP

`bridge.sh` sourcuje `13-esp.sh` po `12-pipeline.sh` i wywoluje
`start_esp_subscribers` w tym samym miejscu, w ktorym wczesniej byly trzy
inline bloki `(while true; ...) &`: po zbudowaniu `SUB_ARGS`, `SUB_EXTRA` i
`STDBUF_BIN`, przed generowaniem `wmbusmeters.conf`.

Wazne inwarianty zachowane w Stage 13:

- Wnetrze przeniesionego bloku ESP jest byte-identical do poprzedniego
  `bridge.sh`.
- Modul nie uruchamia subscriberow przy samym `source`; robi to dopiero
  jawne wywolanie `start_esp_subscribers` w `bridge.sh`.
- Nie zmieniono topikow MQTT ESP ani formatow plikow statusowych WebUI.

Ryzyko do testow runtime: dokumentacja Stage 13 wskazuje, ze opakowanie
background subscriberow funkcja moze zmienic sposob obserwacji PID-ow przy
debugowaniu. Przed wydaniem produkcyjnym warto sprawdzic w kontenerze, ze soft
reload DECODE nadal nie zabija procesow ESP subscriberow.

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
