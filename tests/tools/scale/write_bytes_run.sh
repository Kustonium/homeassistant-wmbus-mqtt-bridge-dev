#!/usr/bin/env bash
# Prod-scale write measurement: 210 meters (10 official, 200 preview candidates),
# 3 unique telegrams/s, each heard by 5 boards (telegram + rx + rssi per board).
set -uo pipefail
REPO=/home/user/homeassistant-wmbus-mqtt-bridge-dev
SP=/tmp/claude-0/-home-user-homeassistant-wmbus-mqtt-bridge-dev/9766cca4-44fa-5a5c-9af7-8cb78a898a84/scratchpad
IMG=ghcr.io/kustonium/amd64-addon-wmbus_mqtt_bridge-dev:1.5.70-dev.337
SECONDS_RUN=${SECONDS_RUN:-480}; WINDOWS=${WINDOWS:-120,480}; V=${V:-main}; STRACE=${STRACE:-1}
E=$SP/io/$V; rm -rf $E; mkdir -p $E/code
$SP/venv/bin/amqtt > $E/broker.log 2>&1 & BROKER=$!
sleep 3
(cd $REPO && git archive ${REF:-origin/main}) | tar -x -C $E/code
for p in ${PATCHES:-}; do (cd $E/code && patch -p1 -s < "$p") || echo "PATCH FAILED: $p"; done
python3 $SP/scale/gen.py $REPO $E $SECONDS_RUN
sed -n "/cat > \"\${OPTIONS_JSON}\" <<'EOFJSON'/,/^EOFJSON/p" $REPO/docker/entrypoint.sh | sed '1d;$d' \
  | jq --slurpfile m $E/official.json '.external_mqtt_host="127.0.0.1" | .meters=$m[0]' > $E/config/options.json
chmod +x $E/code/rootfs/usr/bin/bridge.sh
docker rm -f wmbus-io >/dev/null 2>&1
docker run -d --name wmbus-io --network host -v $E/config:/config \
  -v $E/code/rootfs/usr/bin/bridge.sh:/usr/bin/bridge.sh:ro -v $E/code/rootfs/usr/bin/bridge-lib:/usr/bin/bridge-lib:ro \
  -v $E/code/rootfs/usr/bin/bridge_ledger.py:/usr/bin/bridge_ledger.py:ro \
  --entrypoint /usr/bin/docker-entrypoint.sh $IMG >/dev/null
for _ in $(seq 1 90); do docker logs wmbus-io 2>&1 | grep -q 'Parallel LISTEN instance started' && break; sleep 1; done
sleep 10
cid=$(docker inspect -f '{{.Id}}' wmbus-io)
t0=$(python3 -c 'import time; print(time.time() + 6)')
if [[ $STRACE == 1 ]]; then
  args=(); for p in $(cat /sys/fs/cgroup/pids/docker/$cid/cgroup.procs); do args+=(-p "$p"); done
  strace -f -qq -ttt -y -s 0 -e trace=write,pwrite64,writev,rename,renameat,renameat2 -e signal=none -o $E/strace.log "${args[@]}" 2>/dev/null & ST=$!
  sleep 3
fi
d0=$(awk '$3=="vda"{print $10}' /proc/diskstats)
$SP/venv/bin/python $SP/io/feed.py $E/stream.txt $t0 > $E/feed.out 2>&1
sleep 5
d1=$(awk '$3=="vda"{print $10}' /proc/diskstats)
[[ $STRACE == 1 ]] && { kill $ST; wait $ST 2>/dev/null; }
echo "diskstats vda: $(( (d1 - d0) * 512 / 1000000 )) MB over the run" > $E/disk.txt
docker logs wmbus-io > $E/container.log 2>&1
docker rm -f wmbus-io >/dev/null
kill $BROKER
[[ $STRACE == 1 ]] && python3 $SP/io/attr.py $E/strace.log $t0 $WINDOWS > $E/ranking.txt
echo "raw_count $(cat $E/config/status_raw_count.txt 2>/dev/null) rx_history $(wc -l < $E/config/esp_rf_rx_history.jsonl 2>/dev/null)" >> $E/disk.txt
echo IO-DONE
