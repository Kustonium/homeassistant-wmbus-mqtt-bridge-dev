"""Zamień zrzuty /hardware/info z żywej instancji HA na fixture'y testowe.

Zachowuje to, co ma znaczenie dla logiki pickera portów (VID:PID, obecność/brak
numeru seryjnego, KOLIZJE by-id, by-path, klasy interfejsów), a usuwa identyfikatory
sprzętu użytkownika (numery seryjne, MAC-i, seryjne dysków). Repo jest publiczne.
"""
import json, re, sys
from pathlib import Path

SRC = Path(sys.argv[1])
DST = Path(sys.argv[2])
DST.mkdir(parents=True, exist_ok=True)

SCENARIOS = {
    "1786869604075": ("01-baseline", "SkyConnect (zajety przez integracje) + CH340 bez numeru seryjnego + 4x ttyS"),
    "1786869841875": ("02-rtlsdr", "RTL-SDR wpiety: subsystem usb, ZERO nowych tty"),
    "1786870006897": ("03-esp-single", "Plytka ESP32-S3: tworzy ttyACM0 + unikalne by-id (serial = MAC)"),
    "1786870208102": ("04-esp-two", "Dwie plytki ESP: identyczne VID:PID i lancuch produktu, rozne seriale"),
    "1786870350078": ("05-esp-renumbered", "Po przepieciu ttyACM0 wskazuje INNA plytke niz w 04"),
    "1786871541736": ("06-non-serial", "Pendrive (block) + czytnik kart CCID: brak wplywu na liste tty"),
    "1786871926233": ("07-dvbt-tuner", "Tuner DVB-T ITE 048d:9135, klasa ff0000, ZADEN wezel nie powstal"),
    "1786872117540": ("08-pl2303", "PL2303 bez numeru seryjnego; klasa ff0000 TAK SAMO jak tuner, ale jest tty"),
    "1786872220939": ("09-ch340-collision", "DWA CH340: identyczna sciezka by-id, rozne by-path"),
}

KEEP_ATTRS = ["ID_VENDOR_ID", "ID_MODEL_ID", "ID_VENDOR", "ID_MODEL",
              "ID_SERIAL_SHORT", "ID_USB_INTERFACES", "ID_PATH", "DEVLINKS",
              "DEVTYPE", "ID_BUS"]
KEEP_SUBSYSTEMS = {"tty", "usb", "block"}

serial_map, mac_map = {}, {}


def fake_serial(real: str) -> str:
    if re.fullmatch(r"(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}", real):
        if real not in mac_map:
            n = len(mac_map)
            mac_map[real] = "AA:BB:CC:00:00:%02X" % n
        return mac_map[real]
    if real not in serial_map:
        serial_map[real] = "SERIAL%03d" % len(serial_map)
    return serial_map[real]


def scrub(text: str) -> str:
    """Podmien kazdy znany numer seryjny wszedzie, gdzie wystapi (by-id, DEVLINKS)."""
    for real, fake in list(serial_map.items()) + list(mac_map.items()):
        text = text.replace(real, fake)
    return text


for path in sorted(SRC.glob("*.txt")):
    stamp = re.search(r"(\d{13})", path.name)
    if not stamp or stamp.group(1) not in SCENARIOS:
        continue
    name, desc = SCENARIOS[stamp.group(1)]
    raw = json.loads(path.read_text(encoding="utf-8"))
    devices = raw.get("result", {}).get("devices", [])

    # pierwszy przebieg: zbierz numery seryjne, zeby podmiana byla spojna
    for d in devices:
        s = (d.get("attributes") or {}).get("ID_SERIAL_SHORT")
        if s:
            fake_serial(s)

    out = []
    for d in devices:
        if d.get("subsystem") not in KEEP_SUBSYSTEMS:
            continue
        attrs = {k: v for k, v in (d.get("attributes") or {}).items() if k in KEEP_ATTRS}
        out.append({
            "dev_path": d.get("dev_path"),
            "subsystem": d.get("subsystem"),
            "by_id": d.get("by_id"),
            "attributes": attrs,
        })

    doc = {
        "_fixture": name,
        "_description": desc,
        "_source": "GET /hardware/info (Supervisor) z zywej instancji HAOS, 2026-08-16",
        "_anonymised": "numery seryjne i MAC-i podmienione; struktura unikalnosci i KOLIZJI zachowana",
        "devices": out,
    }
    text = scrub(json.dumps(doc, indent=2, ensure_ascii=False))
    (DST / f"{name}.json").write_text(text + "\n", encoding="utf-8")
    print(f"{name}.json  ({len(out)} urzadzen)")

print(f"\npodmienionych seriali: {len(serial_map)}, MAC-ow: {len(mac_map)}")
