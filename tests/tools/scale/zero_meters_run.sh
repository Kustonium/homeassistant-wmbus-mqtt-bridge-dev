#!/usr/bin/env bash
# Zero configured meters: ~210 meters on air (200 known candidates), 3 unique
# telegrams/s from 5 boards (telegram + rx + rssi). CPU per loop (no strace),
# then strace on the decode loop and the RAW delegation loop for forks/bytes.
set -uo pipefail
REPO=/home/user/homeassistant-wmbus-mqtt-bridge-dev
SP=/tmp/claude-0/-home-user-homeassistant-wmbus-mqtt-bridge-dev/9766cca4-44fa-5a5c-9af7-8cb78a898a84/scratchpad
IMG=ghcr.io/kustonium/amd64-addon-wmbus_mqtt_bridge-dev:1.5.70-dev.337
V=${V:-before}; E=$SP/zero/$V; rm -rf $E; mkdir -p $E/code
$SP/venv/bin/amqtt > $E/broker.log 2>&1 & BROKER=$!
sleep 3
(cd $REPO && git archive ${REF:-origin/main}) | tar -x -C $E/code
python3 $SP/scale/gen.py $REPO $E 330
sed -n "/cat > \"\${OPTIONS_JSON}\" <<'EOFJSON'/,/^EOFJSON/p" $REPO/docker/entrypoint.sh | sed '1d;$d' \
  | jq '.external_mqtt_host="127.0.0.1" | .meters=[]' > $E/config/options.json
chmod +x $E/code/rootfs/usr/bin/bridge.sh
printf '#!/usr/bin/with-contenv bash\nexec /usr/bin/docker-entrypoint.sh\n' > $E/svc_run; chmod +x $E/svc_run
docker rm -f wmbus-zero >/dev/null 2>&1
docker run -d --name wmbus-zero --network host -v $E/config:/config -e WMBUS_BASE=/config \
  -v $E/svc_run:/etc/services.d/wmbus_mqtt_bridge/run:ro \
  -v $E/code/rootfs/usr/bin/bridge.sh:/usr/bin/bridge.sh:ro -v $E/code/rootfs/usr/bin/bridge-lib:/usr/bin/bridge-lib:ro \
  -v $E/code/rootfs/usr/bin/bridge_ledger.py:/usr/bin/bridge_ledger.py:ro $IMG >/dev/null
for _ in $(seq 1 90); do docker logs wmbus-zero 2>&1 | grep -q 'Parallel LISTEN instance started' && break; sleep 1; done
sleep 10
cid=$(docker inspect -f '{{.Id}}' wmbus-zero)
t0=$(python3 -c 'import time; print(time.time() + 4)')
python3 $SP/zero/sampler.py $cid $E/config $t0 120,240 > $E/sampler.out 2>&1 &
SAMP=$!
$SP/venv/bin/python $SP/io/feed.py $E/stream.txt $t0 > $E/feed.out 2>&1 &
FEED=$!
wait $SAMP
pids=$(python3 -c "import ast,sys; d=ast.literal_eval(open('$E/sampler.out').readline()[5:]); print(' '.join(str(p) for k in ('decode_loop','delegation_loop') for p in d.get(k,[])))")
args=(); for p in $pids; do args+=(-p "$p"); done
f0=$(awk '/^processes/{print $2}' /proc/stat)
timeout 60 strace -f -qq -ttt -y -s 0 -e trace=clone,clone3,fork,vfork,write,pwrite64,rename,renameat2 -e signal=none -o $E/strace.log "${args[@]}" 2>/dev/null
f1=$(awk '/^processes/{print $2}' /proc/stat)
echo "host forks during 60 s strace window: $((f1 - f0))" > $E/forks.txt
wait $FEED
docker logs wmbus-zero > $E/container.log 2>&1
docker rm -f wmbus-zero >/dev/null
kill $BROKER
echo ZERO-DONE
