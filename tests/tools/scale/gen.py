# Builds the prod-scale scenario: seeded /config state and the telegram stream.
import json, os, random, sys, time
repo, out, seconds = sys.argv[1], sys.argv[2], int(sys.argv[3])
random.seed(11)
hexof = lambda p: "".join(open(p).read().split()).upper()
Q = hexof(f"{repo}/tests/fixtures/qwaterv2/52632878.hex")
I = hexof(f"{repo}/tests/fixtures/izar/2156B4C2.hex")
def with_id(frame, meter):  # A-field is little-endian at hex 8..16
    return frame[:8] + meter[6:8] + meter[4:6] + meter[2:4] + meter[0:2] + frame[16:]
ids = random.sample(range(10000000, 99999999), 210)
official = [f"{i:08d}" for i in ids[:10]]
qcand = [f"{i:08d}" for i in ids[10:190]]
icand = [f"{i:08d}" for i in ids[190:210]]
cfg = f"{out}/config"
os.makedirs(f"{cfg}/preview/etc/wmbusmeters.d", exist_ok=True)
os.makedirs(f"{cfg}/.preview_decode_last", exist_ok=True)
now = int(time.time())
iso = time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(now - 60))
with open(f"{cfg}/status_candidates.tsv", "w") as c, open(f"{cfg}/status_candidate_preview_state.tsv", "w") as st, \
     open(f"{cfg}/status_candidate_values.tsv", "w") as v:
    for m in qcand + icand:
        drv, typ, mfr = (("qwaterv2", "Water meter (0x07)", "(QDS) Qundis, Germany (0x4493)") if m in qcand
                         else ("izarv2", "water", "(SAP) Diehl Metering"))
        c.write(f"{m}\t{drv}\t{typ}\t{iso}\t40\t70\t12\t50\t{mfr}\n")
        st.write(f"{m}\tdecoded_value\t{iso}\t\n")
        v.write(f"{m}\t12.345\ttotal_m3\t{iso}\n")
        drvline = f"driver={drv}\n"
        open(f"{cfg}/preview/etc/wmbusmeters.d/meter-preview-{m}", "w").write(f"name=preview_{m}\nid={m}\n{drvline}")
        open(f"{cfg}/.preview_decode_last/{m}", "w").write(f"{now - 3600}\n")
open(f"{cfg}/seen_ids.txt", "w").write("".join(m + "\n" for m in official + qcand + icand))
json.dump([{"id": f"meter_{m}", "meter_id": m, "type": "qwaterv2", "type_other": "", "key": ""} for m in official],
          open(f"{out}/official.json", "w"))
# Stream: 3 unique telegrams/s, uniform over the 210 meters, 5 % with a random A-field.
meters = [(m, Q) for m in official + qcand] + [(m, I) for m in icand]
# Every telegram of a meter differs from its previous one (as a real meter's
# do): the last byte counts that meter's telegrams.
count = {}
with open(f"{out}/stream.txt", "w") as s:
    for n in range(seconds * 3):
        m, base = random.choice(meters)
        k = count[m] = count.get(m, random.randrange(256)) + 1
        frame = base[:-2] + f"{k % 256:02X}"
        corrupt = random.random() < 0.05
        if corrupt:
            m = f"{random.randrange(10**7, 10**8):08d}"
        s.write(f"{n}\t{m}\t{int(corrupt)}\t{with_id(frame, m)}\n")
