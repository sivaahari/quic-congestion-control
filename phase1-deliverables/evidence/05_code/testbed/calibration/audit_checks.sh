#!/usr/bin/env bash
# audit_checks.sh - verification checks the dispersion calibration does NOT cover.
#
#   CHECK 1  netem delay is actually applied (and removable)
#   CHECK 2  a SMALL tbf burst can still SUSTAIN the configured rate over a long flow.
#            The dispersion sweep only ever sent a 20-packet train, which by
#            construction cannot detect a burst setting that throttles sustained
#            throughput. This is the other half of the burst trade-off.
#   CHECK 3  one dispersion cell reproduces independently
#
# NOTE ON SOURCE BINDING: ns_client uses source-based routing (ip rule from
# <addr> lookup <table>). The main table has NO route to the service address, so
# a socket that does not bind an explicit source address gets ENETUNREACH. All
# traffic generators here therefore bind explicitly. This mirrors how the QUIC
# client will select a path, so it is a faithful test, but it is a sharp edge.
#
# Must run as ONE invocation: the WSL2 VM tears down namespaces and /tmp when idle.
set -uo pipefail

TB=/home/sivaa/pvseed/testbed
WORK=/home/sivaa/pvseed/results/raw/_audit
mkdir -p "$WORK"

echo "###############  AUDIT (checks 2 and 3)  ###############"

bash "$TB/topology/setup_topology.sh" >/dev/null 2>&1 || { echo "TOPOLOGY SETUP FAILED"; exit 1; }
echo "topology up"

cat > "$WORK/tcp_sink.py" <<'PYEOF'
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((sys.argv[1], 5555)); s.listen(1)
s.settimeout(20)
try:
    c, _ = s.accept()
except Exception as e:
    print("ACCEPT_TIMEOUT"); sys.exit(1)
c.settimeout(20)
n = 0; t0 = None
try:
    while True:
        b = c.recv(262144)
        if not b: break
        if t0 is None: t0 = time.perf_counter()
        n += len(b)
except Exception:
    pass
t1 = time.perf_counter()
dur = (t1 - t0) if t0 else 0
print("%.3f" % ((n*8/dur)/1e6 if dur > 0 else 0))
PYEOF

cat > "$WORK/tcp_blast.py" <<'PYEOF'
import socket, sys, time
s = socket.socket()
s.bind((sys.argv[3], 0))          # explicit source bind - required by source-based routing
s.settimeout(10)
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

echo
echo "--- CHECK 2: SUSTAINED throughput vs burst (configured 50 Mbit, 6s TCP flow) ---"
for BURST in 1600 3200 8000 32000 128000; do
    bash "$TB/shaping/apply_shaping.sh" a down 50 0 0 "$BURST" 1000 >/dev/null 2>&1
    : > "$WORK/sink_out.txt"
    ip netns exec ns_server timeout 30 python3 "$WORK/tcp_sink.py" 10.0.9.1 > "$WORK/sink_out.txt" 2>/dev/null &
    SINK_PID=$!
    sleep 0.7
    ip netns exec ns_client timeout 25 python3 "$WORK/tcp_blast.py" 10.0.9.1 6 10.0.1.1 >/dev/null 2>&1
    wait $SINK_PID 2>/dev/null
    ACHIEVED=$(cat "$WORK/sink_out.txt" 2>/dev/null)
    [ -z "$ACHIEVED" ] && ACHIEVED="FAIL"
    printf "  burst=%7sB  configured=50.000 Mbit  achieved=%9s Mbit\n" "$BURST" "$ACHIEVED"
done

echo
echo "--- CHECK 2b: sustained throughput at 100 Mbit, burst 1600 vs 3200 ---"
for BURST in 1600 3200; do
    bash "$TB/shaping/apply_shaping.sh" a down 100 0 0 "$BURST" 1000 >/dev/null 2>&1
    : > "$WORK/sink_out.txt"
    ip netns exec ns_server timeout 30 python3 "$WORK/tcp_sink.py" 10.0.9.1 > "$WORK/sink_out.txt" 2>/dev/null &
    SINK_PID=$!
    sleep 0.7
    ip netns exec ns_client timeout 25 python3 "$WORK/tcp_blast.py" 10.0.9.1 6 10.0.1.1 >/dev/null 2>&1
    wait $SINK_PID 2>/dev/null
    ACHIEVED=$(cat "$WORK/sink_out.txt" 2>/dev/null)
    [ -z "$ACHIEVED" ] && ACHIEVED="FAIL"
    printf "  burst=%7sB  configured=100.000 Mbit  achieved=%9s Mbit\n" "$BURST" "$ACHIEVED"
done

echo
echo "--- CHECK 3: reproduce one dispersion cell (50 Mbit, burst 1600) ---"
bash "$TB/shaping/apply_shaping.sh" a down 50 0 0 1600 1000 >/dev/null 2>&1
for i in 1 2 3; do
    ip netns exec ns_client timeout 20 python3 "$TB/calibration/udp_train.py" \
        --mode receiver --bind 10.0.1.1 --port 9999 --count 20 --out "$WORK/aud_$i.json" 2>/dev/null &
    RPID=$!
    sleep 0.4
    ip netns exec ns_server timeout 20 python3 "$TB/calibration/udp_train.py" \
        --mode sender --dst 10.0.1.1 --port 9999 --count 20 --size 1200 >/dev/null 2>&1
    wait $RPID 2>/dev/null
    python3 -c "
import json
d=json.load(open('$WORK/aud_$i.json'))
s=d['summary']
print('  rep $i: median=%.3f Mbit  iqr/med=%.4f  rcvd=%d/%d' % (s['median_rate_bps']/1e6, s['iqr_over_median'], d['packets_received'], d['packets_sent']))
" 2>/dev/null || echo "  rep $i: FAILED"
done

echo
bash "$TB/topology/teardown_topology.sh" >/dev/null 2>&1 && echo "teardown clean"
echo "###############  AUDIT END  ###############"
