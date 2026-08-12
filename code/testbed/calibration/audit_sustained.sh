#!/usr/bin/env bash
# audit_sustained.sh - CHECK 2 (corrected direction).
#
# Verifies that a SMALL tbf burst can still SUSTAIN the configured rate over a
# long flow. The dispersion sweep only sent a 20-packet train, which cannot
# detect a burst that throttles sustained throughput -- the other half of the
# burst trade-off.
#
# DIRECTION MATTERS: `apply_shaping.sh a down` shapes the SERVER->CLIENT egress
# (ba_c). The traffic generator must therefore run server->client, i.e. the
# blaster lives in ns_server and the sink lives in ns_client. Running it the
# other way traverses the unshaped uplink and measures raw veth speed
# (~30 Gbit/s), which is a test bug, not a shaping failure.
set -uo pipefail

TB=/home/sivaa/pvseed/testbed
WORK=/home/sivaa/pvseed/results/raw/_audit
mkdir -p "$WORK"

bash "$TB/topology/setup_topology.sh" >/dev/null 2>&1 || { echo "TOPOLOGY SETUP FAILED"; exit 1; }
echo "topology up"

cat > "$WORK/sink.py" <<'PYEOF'
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((sys.argv[1], 5555)); s.listen(1); s.settimeout(25)
try:
    c, _ = s.accept()
except Exception:
    print("ACCEPT_TIMEOUT"); sys.exit(1)
c.settimeout(25)
n = 0; t0 = None
try:
    while True:
        b = c.recv(262144)
        if not b: break
        if t0 is None: t0 = time.perf_counter()
        n += len(b)
except Exception:
    pass
dur = (time.perf_counter() - t0) if t0 else 0
print("%.3f" % ((n*8/dur)/1e6 if dur > 0 else 0))
PYEOF

cat > "$WORK/blast.py" <<'PYEOF'
import socket, sys, time
# argv: dst  duration  src
s = socket.socket()
s.bind((sys.argv[3], 0))
s.settimeout(15)
s.connect((sys.argv[1], 5555))
buf = b'x' * 65536
end = time.perf_counter() + float(sys.argv[2])
try:
    while time.perf_counter() < end:
        s.sendall(buf)
except Exception as e:
    print("BLAST_ERR", e, file=sys.stderr)
s.close()
PYEOF

run_cell() {           # rate_mbit  burst
    local RATE=$1 BURST=$2
    bash "$TB/shaping/apply_shaping.sh" a down "$RATE" 0 0 "$BURST" 1000 >/dev/null 2>&1
    : > "$WORK/sink_out.txt"
    # sink in ns_CLIENT (receives the shaped downlink)
    ip netns exec ns_client timeout 40 python3 "$WORK/sink.py" 10.0.1.1 > "$WORK/sink_out.txt" 2>/dev/null &
    local SP=$!
    sleep 0.7
    # blaster in ns_SERVER (sends over the shaped downlink)
    ip netns exec ns_server timeout 35 python3 "$WORK/blast.py" 10.0.1.1 6 10.0.9.1 >/dev/null 2>&1
    wait $SP 2>/dev/null
    local A; A=$(cat "$WORK/sink_out.txt" 2>/dev/null); [ -z "$A" ] && A=FAIL
    printf "  rate=%4s Mbit  burst=%7sB   achieved=%9s Mbit\n" "$RATE" "$BURST" "$A"
}

echo
echo "--- SUSTAINED throughput, server->client (shaped downlink), 6s TCP ---"
for RATE in 5 50 100; do
    for BURST in 1600 3200 8000 32000; do
        run_cell "$RATE" "$BURST"
    done
    echo
done

bash "$TB/topology/teardown_topology.sh" >/dev/null 2>&1 && echo "teardown clean"
