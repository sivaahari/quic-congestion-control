#!/usr/bin/env bash
# verify_routing.sh
#
# Regression test for Phase-0 audit FINDING 1 ("unbound sockets have no
# route"). Proves, with interface packet COUNTERS and tcpdump captures (not
# assumption), that in ns_client:
#
#   (a) an UNBOUND socket (no explicit source bind) can reach SERVICE_IP at
#       all -- before the fix this hung with ENETUNREACH -- and that it
#       deterministically takes PATH A (cli_a / ns_bottle_a).
#   (b) a socket explicitly bound to CLI_A_IP still takes PATH A.
#   (c) a socket explicitly bound to CLI_B_IP still takes PATH B
#       (cli_b / ns_bottle_b), proving the new main-table fallback route
#       does NOT shadow the source-based policy rules.
#
# Method: for each sub-test, snapshot tx packet counters on BOTH cli_a and
# cli_b in ns_client before and after a small UDP exchange, and
# independently run an UNFILTERED tcpdump on both interfaces over the same
# window. The tcpdump content (grepped for the service address) is the
# authoritative, protocol-aware proof of which path actually carried OUR
# traffic; the raw packet counters are a coarser cross-check that can
# include unrelated control-plane packets (e.g. ARP) and are reported for
# transparency but do not by themselves fail the test.
#
# Self-contained: sets up topology, runs all three checks, tears down.
# Safe to re-run: uses its own scratch dir under results/raw (not /tmp).
set -uo pipefail

TB=/home/sivaa/pvseed/testbed
WORK=/home/sivaa/pvseed/results/raw/_verify_routing
PORT=7100
NPKTS=5
mkdir -p "$WORK"
rm -f "$WORK"/*.log "$WORK"/*.py

log() { printf '[verify_routing] %s\n' "$*"; }

FAIL=0

if ! bash "$TB/topology/setup_topology.sh" > "$WORK/setup.log" 2>&1; then
    echo "TOPOLOGY SETUP FAILED -- see $WORK/setup.log"
    tail -n 40 "$WORK/setup.log"
    exit 1
fi
log "topology up"

# --- tiny helper programs -----------------------------------------------

cat > "$WORK/rx.py" <<'PYEOF'
# argv: bind_ip port n_expected
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((sys.argv[1], int(sys.argv[2])))
s.settimeout(6)
got = 0
try:
    for _ in range(int(sys.argv[3])):
        s.recvfrom(2048)
        got += 1
except socket.timeout:
    pass
print(f"RX_GOT={got}")
PYEOF

cat > "$WORK/tx_unbound.py" <<'PYEOF'
# argv: dst port n
# Deliberately NO bind() before connect() -- this is exactly the socket
# shape that produced ENETUNREACH before the FINDING 1 fix.
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.connect((sys.argv[1], int(sys.argv[2])))
for _ in range(int(sys.argv[3])):
    s.send(b"x" * 32)
print("SEND_OK unbound")
PYEOF

cat > "$WORK/tx_bound.py" <<'PYEOF'
# argv: src dst port n
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((sys.argv[1], 0))
s.connect((sys.argv[2], int(sys.argv[3])))
for _ in range(int(sys.argv[4])):
    s.send(b"x" * 32)
print(f"SEND_OK bound-src={sys.argv[1]}")
PYEOF

read_counter() {
    ip netns exec ns_client cat "/sys/class/net/$1/statistics/$2"
}

# run_subtest <label> <expected_if> <other_if> <send_cmd...>
run_subtest() {
    local label=$1 expect_if=$2 other_if=$3
    shift 3

    local before_exp_tx before_oth_tx after_exp_tx after_oth_tx
    before_exp_tx=$(read_counter "$expect_if" tx_packets)
    before_oth_tx=$(read_counter "$other_if" tx_packets)

    local cap_exp="$WORK/tcpdump_${label}_${expect_if}.log"
    local cap_oth="$WORK/tcpdump_${label}_${other_if}.log"
    # Unfiltered (any protocol) so any stray non-test packet (e.g. ARP) is
    # visible in the log for manual inspection, rather than silently
    # dropped by a capture-time filter.
    ip netns exec ns_client timeout 5 tcpdump -i "$expect_if" -n -q -e \
        > "$cap_exp" 2>/dev/null &
    local tcpdump_exp_pid=$!
    ip netns exec ns_client timeout 5 tcpdump -i "$other_if" -n -q -e \
        > "$cap_oth" 2>/dev/null &
    local tcpdump_oth_pid=$!
    sleep 0.4   # let both tcpdump instances attach before traffic starts

    : > "$WORK/rx_${label}.log"
    ip netns exec ns_server timeout 7 python3 "$WORK/rx.py" 10.0.9.1 "$PORT" "$NPKTS" \
        > "$WORK/rx_${label}.log" 2>&1 &
    local rx_pid=$!
    sleep 0.3

    "$@" > "$WORK/tx_${label}.log" 2>&1
    local send_rc=$?

    wait "$rx_pid" 2>/dev/null
    wait "$tcpdump_exp_pid" 2>/dev/null
    wait "$tcpdump_oth_pid" 2>/dev/null

    after_exp_tx=$(read_counter "$expect_if" tx_packets)
    after_oth_tx=$(read_counter "$other_if" tx_packets)

    local d_exp=$(( after_exp_tx - before_exp_tx ))
    local d_oth=$(( after_oth_tx - before_oth_tx ))
    local cap_exp_n cap_oth_n
    cap_exp_n=$(grep -c "10\.0\.9\.1" "$cap_exp" || true)
    cap_oth_n=$(grep -c "10\.0\.9\.1" "$cap_oth" || true)
    local rx_got
    rx_got=$(grep -o 'RX_GOT=[0-9]*' "$WORK/rx_${label}.log" || echo "RX_GOT=MISSING")

    echo
    log "--- subtest: $label (expect traffic on $expect_if, NOT on $other_if) ---"
    log "send_rc=$send_rc  tx($expect_if): $before_exp_tx -> $after_exp_tx (delta=$d_exp)   tx($other_if): $before_oth_tx -> $after_oth_tx (delta=$d_oth)"
    log "tcpdump pkts-to-10.0.9.1: $expect_if=$cap_exp_n  $other_if=$cap_oth_n   server-side $rx_got (sent $NPKTS)"

    if [ "$send_rc" -ne 0 ]; then
        log "FAIL($label): sender exited non-zero -- $(cat "$WORK/tx_${label}.log")"
        FAIL=1
    fi
    if [ "$rx_got" != "RX_GOT=$NPKTS" ]; then
        log "FAIL($label): server did not receive all $NPKTS packets ($rx_got)"
        FAIL=1
    fi
    if [ "$d_exp" -lt "$NPKTS" ]; then
        log "FAIL($label): expected interface $expect_if only saw $d_exp new tx packets (wanted >= $NPKTS)"
        FAIL=1
    fi
    if [ "$cap_exp_n" -lt "$NPKTS" ]; then
        log "FAIL($label): tcpdump on $expect_if only captured $cap_exp_n packets to 10.0.9.1 (wanted >= $NPKTS)"
        FAIL=1
    fi
    if [ "$cap_oth_n" -ne 0 ]; then
        log "FAIL($label): tcpdump on $other_if captured $cap_oth_n packets TO/FROM 10.0.9.1 -- actual test traffic leaked onto the wrong path"
        FAIL=1
    fi
    if [ "$d_oth" -ne 0 ]; then
        log "NOTE($label): other interface $other_if tx_packets counter moved by $d_oth during the window; full unfiltered capture below to identify it (this does NOT by itself fail the test -- tcpdump content to 10.0.9.1, checked above, is the authoritative signal for OUR traffic):"
        sed "s/^/[verify_routing][tcpdump:$other_if] /" "$cap_oth"
    fi
    if [ "$send_rc" -eq 0 ] && [ "$rx_got" = "RX_GOT=$NPKTS" ] && [ "$d_exp" -ge "$NPKTS" ] && [ "$cap_exp_n" -ge "$NPKTS" ] && [ "$cap_oth_n" -eq 0 ]; then
        log "PASS($label): traffic confirmed on $expect_if only, via both counters and tcpdump (protocol-aware capture is authoritative for the OTHER interface; see NOTE above if its raw packet counter also moved)"
    fi
}

echo
log "=== TEST (a): UNBOUND socket -> must succeed and take PATH A ==="
run_subtest "unbound" cli_a cli_b \
    ip netns exec ns_client python3 "$WORK/tx_unbound.py" 10.0.9.1 "$PORT" "$NPKTS"

echo
log "=== TEST (b): socket explicitly bound to CLI_A_IP (10.0.1.1) -> must take PATH A ==="
run_subtest "bound_a" cli_a cli_b \
    ip netns exec ns_client python3 "$WORK/tx_bound.py" 10.0.1.1 10.0.9.1 "$PORT" "$NPKTS"

echo
log "=== TEST (c): socket explicitly bound to CLI_B_IP (10.0.3.1) -> must take PATH B ==="
run_subtest "bound_b" cli_b cli_a \
    ip netns exec ns_client python3 "$WORK/tx_bound.py" 10.0.3.1 10.0.9.1 "$PORT" "$NPKTS"

echo
bash "$TB/topology/teardown_topology.sh" > "$WORK/teardown.log" 2>&1
log "teardown done"

echo
if [ "$FAIL" -eq 0 ]; then
    log "VERDICT: ALL SUBTESTS PASSED -- unbound sockets reach the service via path A; explicit binds are unaffected"
    exit 0
else
    log "VERDICT: AT LEAST ONE SUBTEST FAILED -- see above"
    exit 1
fi
