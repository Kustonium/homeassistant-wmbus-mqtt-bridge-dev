/*
 * Symulator licznika M-Bus (przewodowego) na ESP8266 z mostkiem CH340.
 * Symulator do testowania dialogu odpytywania — patrz docs/ARCHITECTURE.md §5.4.
 *
 * WERSJA 3 (2026-08-17): dodane prawdziwe ramki przewodowe p8 i p9 z testów
 * wmbusmeters: woda aptmbusna oraz energia elektryczna nemo.
 *
 * UWAGA NA JEDYNY UART
 *   ESP8266 ma jeden użyteczny UART i jest to ten sam, który idzie przez CH340.
 *   NIE WOLNO używać Serial.print() — logi trafiłyby prosto w "magistralę".
 *   Diagnostyka tylko przez Serial1 (GPIO2, tylko TX) i tylko gdy DIAG=1.
 *   Na D1 mini GPIO2 = D4 dzieli pin z wbudowaną diodą.
 *
 * SCENARIUSZE WYBIERANE ADRESEM (jeden wsad, wszystkie przypadki)
 *   p1  odpowiada poprawnie
 *   p2  milczy                        -> stan no_reply
 *   p3  odpowiada po SLOW_DELAY_MS    -> spóźniona odpowiedź
 *   p4  odpowiada nie-M-Busem         -> wykrywanie obcego protokołu (DLMS)
 *   p5  odpowiada samym E5 na REQ_UD2 -> niezgodnie ze specyfikacją
 *   p6  DWA liczniki na jednym adresie: dwie ramki po sobie, RÓŻNE id
 *   p7  ramka z ZEPSUTĄ sumą kontrolną (elektryczna nakładka dwóch nadajników)
 *   p8  poprawny wodomierz aptmbusna     -> total_m3, volume_flow_m3h
 *   p9  poprawny licznik energii nemo    -> kWh, kW
 *   0xFE broadcast testowy — sonda "czy magistrala zyje" (odpowiada ACK + ramka)
 *   inne adresy: cisza
 *
 * DLACZEGO KOLIZJA W DWÓCH WARIANTACH
 *   Na prawdziwej magistrali dwa liczniki pod tym samym adresem pierwotnym
 *   nadają JEDNOCZEŚNIE i master widzi elektryczną nakładkę — czyli ramkę
 *   uszkodzoną (p7). Ale spotyka się też sytuację, w której odpowiadają
 *   sekwencyjnie i master dostaje dwie poprawne ramki o różnych id (p6).
 *   Jeden nadajnik nie odtworzy nakładki fizycznie, więc p7 ją udaje psując
 *   sumę kontrolną. To jest przybliżenie i tak trzeba je traktować.
 */

// ---------------------------------------------------------------- konfiguracja
static const uint8_t ADDR_OK = 0x01;
static const uint8_t ADDR_SILENT = 0x02;
static const uint8_t ADDR_SLOW = 0x03;
static const uint8_t ADDR_GARBAGE = 0x04;
static const uint8_t ADDR_ACK_ONLY = 0x05;
static const uint8_t ADDR_TWO_METERS = 0x06;
static const uint8_t ADDR_BAD_CS = 0x07;
static const uint8_t ADDR_WATER = 0x08;
static const uint8_t ADDR_ELECTRICITY = 0x09;
// 0xFE = broadcast TESTOWY wg EN 13757-2: odpowiadaja WSZYSTKIE liczniki.
// Sluzy jako sonda "czy na kablu w ogole cos jest" — jedno zapytanie zamiast
// skanu 250 adresow. Nie mylic z 0xFF (broadcast BEZ odpowiedzi), ktorego
// uzywa deviceReset() w mbus_rawtty.cc:109.
static const uint8_t ADDR_TEST_BCAST = 0xFE;

static const uint32_t SLOW_DELAY_MS = 3000;
static const uint32_t RESYNC_MS = 100;
static const uint16_t TWO_METERS_GAP_MS = 50;  // odstęp między dwiema ramkami w p6
static const uint8_t DIAG = 0;

// -------------------------------------------------------------------- protokół
static const uint8_t C_SND_NKE = 0x40;    // reset łącza  -> mbus_rawtty.cc:109
static const uint8_t C_REQ_UD2_0 = 0x5B;  // FCB=0        -> meters.cc:882
static const uint8_t C_REQ_UD2_1 = 0x7B;  // FCB=1        -> meters.cc:883
static const uint8_t ACK = 0xE5;
static const uint8_t START_SHORT = 0x10;
static const uint8_t START_LONG = 0x68;
static const uint8_t STOP = 0x16;

/*
 * Pole użytkownika odpowiedzi RSP_UD (C, A, CI + dane), 56 bajtów.
 * Z korpusu upstreamu: tests/test_libmbus_secondary_address.sh, wmbusmeters
 * v3.0.0 (ac4f295). Dekoduje się driverem piigth do temperature_c = 23.02.
 *
 * Bajty 3..6 to id w little endian: 84 02 00 10 = 10000284.
 * Adres (bajt 1) i id są podmieniane w runtime, suma kontrolna przeliczana.
 */
static const uint8_t RSP_USER[] = {
  0x08, 0x00, 0x72, 0x84, 0x02, 0x00, 0x10, 0x29, 0x41, 0x01, 0x1B,
  0x0D, 0x00, 0x00, 0x00, 0x02, 0x65, 0xFE, 0x08, 0x42, 0x65, 0x30,
  0x09, 0x82, 0x01, 0x65, 0xE7, 0x08, 0x02, 0xFB, 0x1A, 0x48, 0x01,
  0x42, 0xFB, 0x1A, 0x45, 0x01, 0x82, 0x01, 0xFB, 0x1A, 0x4E, 0x01,
  0x0C, 0x78, 0x84, 0x02, 0x00, 0x10, 0x02, 0xFD, 0x0F, 0x21, 0x00,
  0x0F
};
static const uint8_t RSP_USER_LEN = sizeof(RSP_USER);  // = 56 = 0x38

// Drugi "licznik" dla p6: id 66778899 (little endian 99 88 77 66).
static const uint8_t ALT_ID[4] = { 0x99, 0x88, 0x77, 0x66 };

/*
 * Pełne ramki z testów upstream wmbusmeters v3:
 *   drivers/src/aptmbusna.xmq -> id 00683775, total_m3=16.119,
 *                                volume_flow_m3h=0.013
 *   drivers/src/nemo.xmq      -> id 00067609,
 *                                total_active_positive_3phase_kwh=6735835,
 *                                active_positive_3phase_kw=97.83
 *
 * Pole A (indeks 5) jest podmieniane na adres pierwotny p8/p9, a suma
 * kontrolna jest przeliczana przed wysłaniem. Pozostałe bajty są zachowane.
 */
static const uint8_t FRAME_WATER[] = {
  0x68, 0x56, 0x56, 0x68, 0x08, 0x00, 0x72, 0x75, 0x37, 0x68, 0x00, 0x01,
  0x06, 0x15, 0x07, 0xCC, 0xE8, 0x00, 0x00, 0x0C, 0x78, 0x75, 0x37, 0x68,
  0x00, 0x04, 0x6D, 0x1D, 0xB4, 0x58, 0x34, 0x04, 0x13, 0xF7, 0x3E, 0x00,
  0x00, 0x02, 0x3B, 0x0D, 0x00, 0x44, 0x13, 0x85, 0x01, 0x00, 0x00, 0x42,
  0x6C, 0x41, 0x34, 0x02, 0x27, 0x09, 0x02, 0x03, 0xFD, 0x17, 0x1C, 0x03,
  0x00, 0x04, 0xFF, 0x0A, 0x04, 0x04, 0x00, 0x00, 0x02, 0xFF, 0x0B, 0x00,
  0x00, 0x03, 0xFF, 0x0C, 0x13, 0x00, 0xB2, 0x0F, 0x00, 0x04, 0x2C, 0x1B,
  0x1B, 0x00, 0x01, 0x02, 0x00, 0x00, 0x37, 0x16
};

static const uint8_t FRAME_ELECTRICITY[] = {
  0x68, 0x64, 0x64, 0x68, 0x08, 0x65, 0x72, 0x09, 0x76, 0x06, 0x00, 0xA5,
  0x25, 0x1D, 0x02, 0x00, 0x00, 0x00, 0x00, 0x8E, 0x50, 0x04, 0x00, 0x35,
  0x58, 0x73, 0x06, 0x00, 0x85, 0x50, 0x2B, 0x00, 0x13, 0xBF, 0x47, 0x8E,
  0x90, 0x40, 0x04, 0x00, 0x29, 0x45, 0x25, 0x01, 0x00, 0x85, 0x90, 0x40,
  0x2B, 0x00, 0xF8, 0x00, 0x46, 0x8E, 0x60, 0x04, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x85, 0x60, 0x2B, 0x00, 0x00, 0x00, 0x00, 0x8E, 0xA0, 0x40,
  0x04, 0x00, 0x89, 0x00, 0x00, 0x00, 0x00, 0x85, 0xA0, 0x40, 0x2B, 0x00,
  0x00, 0x00, 0x00, 0x05, 0xFD, 0x3A, 0xDC, 0xF9, 0x7E, 0x3F, 0x01, 0xFD,
  0x17, 0x00, 0x1F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x91, 0x16
};

// Coś, co NIE ma kształtu ramki M-Bus — nagłówek w stylu DLMS/COSEM.
static const uint8_t GARBAGE[] = { 0x7E, 0xA0, 0x2B, 0x03, 0x02, 0x30, 0x00, 0x11 };

// ------------------------------------------------------------------- stan pętli
static uint8_t buf[8];
static uint8_t buf_len = 0;
static uint32_t last_byte = 0;

static uint32_t pending_at = 0;
static uint8_t pending_addr = 0;

// Odroczona druga ramka scenariusza p6.
static uint32_t second_at = 0;
static uint8_t second_addr = 0;

static void diag(const char *msg) {
  if (DIAG) { Serial1.println(msg); }
}

/*
 * Odpowiedź RSP_UD.
 *   addr    – wstawiany w pole A
 *   id4     – nullptr = zostaw oryginalne id; inaczej 4 bajty little endian
 *   breakCs – true = celowo zepsuj sumę kontrolną (udawana nakładka)
 */
static void sendLongFrame(uint8_t addr, const uint8_t *id4, bool breakCs) {
  uint8_t user[RSP_USER_LEN];
  memcpy(user, RSP_USER, RSP_USER_LEN);
  user[1] = addr;
  if (id4 != nullptr) {
    user[3] = id4[0];
    user[4] = id4[1];
    user[5] = id4[2];
    user[6] = id4[3];
  }

  uint16_t cs = 0;
  for (uint8_t i = 0; i < RSP_USER_LEN; i++) cs += user[i];
  uint8_t cs8 = (uint8_t)(cs & 0xFF);
  if (breakCs) cs8 = (uint8_t)(cs8 ^ 0x5A);  // dowolna nieprawidłowa wartość

  Serial.write(START_LONG);
  Serial.write(RSP_USER_LEN);
  Serial.write(RSP_USER_LEN);
  Serial.write(START_LONG);
  Serial.write(user, RSP_USER_LEN);
  Serial.write(cs8);
  Serial.write(STOP);
  Serial.flush();
}

static void sendTemplateFrame(uint8_t addr, const uint8_t *source, size_t len) {
  // Najdłuższa obecna ramka ma 106 bajtów; jawny limit chroni stos, gdy ktoś
  // później wklei większy fixture bez zwiększenia bufora.
  uint8_t frame[112];
  if (len < 8 || len > sizeof(frame)) return;
  memcpy(frame, source, len);
  frame[5] = addr;  // pole A
  uint16_t cs = 0;
  for (size_t i = 4; i < len - 2; i++) cs += frame[i];
  frame[len - 2] = (uint8_t)(cs & 0xFF);
  Serial.write(frame, len);
  Serial.flush();
}

static void answerReqUd2(uint8_t addr) {
  switch (addr) {
    case ADDR_OK:
      sendLongFrame(addr, nullptr, false);
      break;
    case ADDR_SILENT:
      diag("p2: cisza");
      break;
    case ADDR_SLOW:
      pending_at = millis() + SLOW_DELAY_MS;
      pending_addr = addr;
      diag("p3: odpowiedz odroczona");
      break;
    case ADDR_GARBAGE:
      Serial.write(GARBAGE, sizeof(GARBAGE));
      Serial.flush();
      break;
    case ADDR_ACK_ONLY:
      Serial.write(ACK);
      Serial.flush();
      break;
    case ADDR_TWO_METERS:
      // Pierwszy "licznik" odpowiada od razu, drugi po krótkiej chwili.
      sendLongFrame(addr, nullptr, false);
      second_at = millis() + TWO_METERS_GAP_MS;
      second_addr = addr;
      diag("p6: pierwsza ramka wyslana, druga za chwile");
      break;
    case ADDR_BAD_CS:
      sendLongFrame(addr, nullptr, true);
      diag("p7: ramka z zepsuta suma");
      break;
    case ADDR_WATER:
      sendTemplateFrame(addr, FRAME_WATER, sizeof(FRAME_WATER));
      diag("p8: aptmbusna water");
      break;
    case ADDR_ELECTRICITY:
      sendTemplateFrame(addr, FRAME_ELECTRICITY, sizeof(FRAME_ELECTRICITY));
      diag("p9: nemo electricity M-Bus");
      break;
    case ADDR_TEST_BCAST:
      // Na broadcast testowy odpowiada kazdy licznik. Pojedynczy symulator
      // odda jedna czysta ramke — na prawdziwej magistrali z kilkoma
      // licznikami odpowiedzi naloza sie i wroca uszkodzone. To NIE jest
      // usterka, tylko oczekiwane zachowanie 0xFE.
      sendLongFrame(addr, nullptr, false);
      diag("0xFE: odpowiedz na sonde");
      break;
    default:
      // Nieznany adres: cisza, jak martwy licznik.
      break;
  }
}

// Ramka krótka: 10 C A CS 16, gdzie CS = (C + A) & 0xFF.
static void handleShortFrame(uint8_t c, uint8_t a) {
  if (c == C_SND_NKE) {
    // Reset łącza potwierdzają adresy, które w ogóle "istnieją".
    // 0xFF to broadcast bez odpowiedzi (mbus_rawtty.cc:109) — milczymy.
    if (a == ADDR_OK || a == ADDR_SLOW || a == ADDR_GARBAGE ||
        a == ADDR_ACK_ONLY || a == ADDR_TWO_METERS || a == ADDR_BAD_CS ||
        a == ADDR_WATER || a == ADDR_ELECTRICITY ||
        a == ADDR_TEST_BCAST) {   // 0xFE: sonda zycia magistrali
      Serial.write(ACK);
      Serial.flush();
    }
    return;
  }
  if (c == C_REQ_UD2_0 || c == C_REQ_UD2_1) {
    // FCB rozróżnia kolejne żądania; prawdziwy licznik przełączałby zestaw
    // danych, symulator odpowiada tym samym — do testu dialogu wystarcza.
    answerReqUd2(a);
  }
}

void setup() {
  // 2400 8E1 — parzystość EVEN wymusza sam dekoder:
  // createSerialDeviceTTY(dev, bps, PARITY::EVEN, "mbus")
  Serial.begin(2400, SERIAL_8E1);
  if (DIAG) Serial1.begin(115200);
  diag("mbus slave sim v2 start");
}

void loop() {
  uint32_t now = millis();

  // Odroczona odpowiedź scenariusza p3.
  if (pending_at && (int32_t)(now - pending_at) >= 0) {
    sendLongFrame(pending_addr, nullptr, false);
    pending_at = 0;
  }

  // Druga ramka scenariusza p6 — inne id, ten sam adres.
  if (second_at && (int32_t)(now - second_at) >= 0) {
    sendLongFrame(second_addr, ALT_ID, false);
    second_at = 0;
  }

  // Cisza na linii dłuższa niż RESYNC_MS = porzuć niedokończoną ramkę.
  if (buf_len && (now - last_byte) > RESYNC_MS) {
    buf_len = 0;
  }

  while (Serial.available()) {
    uint8_t b = Serial.read();
    last_byte = now;

    if (buf_len == 0 && b != START_SHORT) {
      // Długie ramki od mastera (SND_UD) i śmieci — pomijamy świadomie.
      continue;
    }
    if (buf_len < sizeof(buf)) buf[buf_len++] = b;

    if (buf_len == 5) {
      uint8_t c = buf[1], a = buf[2], cs = buf[3], stop = buf[4];
      if (stop == STOP && cs == (uint8_t)((c + a) & 0xFF)) {
        handleShortFrame(c, a);
      } else {
        diag("zla ramka krotka");
      }
      buf_len = 0;
    }
  }

  yield();
}
