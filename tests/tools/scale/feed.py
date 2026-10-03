# Publishes the prod-scale stream: per telegram, from each of 5 boards,
# wmbus/<b>/telegram (hex), wmbus/<b>/rx (JSON) and wmbus/<b>/rssi/<id>.
import asyncio, sys, time, zlib
from amqtt.client import MQTTClient
stream, t0 = sys.argv[1], float(sys.argv[2])
boards = ["b1", "b2", "b3", "b4", "b5"]
async def main():
    c = MQTTClient(config={"auto_reconnect": False})
    await c.connect("mqtt://127.0.0.1:1883/")
    seq = {b: 0 for b in boards}
    rows = [l.rstrip("\n").split("\t") for l in open(stream)]
    while time.time() < t0: await asyncio.sleep(0.01)
    for n, (_, meter, _, frame) in enumerate(rows):
        due = t0 + n / 3.0
        d = due - time.time()
        if d > 0: await asyncio.sleep(d)
        crc = f"{zlib.crc32(bytes.fromhex(frame)):08X}"
        for i, b in enumerate(boards):
            seq[b] += 1
            rx = ('{"schema":1,"boot_id":"A84F12C%d","seq":%d,"rx_task_wakeup_us":1,"meter_id":"%s","mode":"T1",'
                  '"rssi_dbm":%d,"frame_crc32":"%s","frame_length":%d,"received_at":"%s"}'
                  % (i, seq[b], meter, -55 - 3 * i, crc, len(frame) // 2,
                     time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())))
            await c.publish(f"wmbus/{b}/telegram", frame.encode(), qos=0)
            await c.publish(f"wmbus/{b}/rx", rx.encode(), qos=0)
            await c.publish(f"wmbus/{b}/rssi/{meter}", str(-55 - 3 * i).encode(), qos=0)
    await asyncio.sleep(2)
    await c.disconnect()
asyncio.run(main())
