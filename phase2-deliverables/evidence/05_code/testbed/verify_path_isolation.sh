#!/usr/bin/env bash
# verify_path_isolation.sh
#
# Guards against a subtle, project-invalidating failure: after adding a
# main-table fallback route to ns_client (so unbound sockets can route), an
# explicit bind to the path-B address must STILL traverse path B. If the
# fallback route silently captured path-B traffic, both "paths" would in fact
# be path A and every migration experiment would be measuring nothing.
#
# Proof is by per-interface packet counters, not by assumption.
set -uo pipefail

TB=/home/sivaa/pvseed/testbed
bash "$TB/topology/setup_topology.sh" >/dev/null 2>&1 || { echo "SETUP FAILED"; exit 1; }
echo "topology up"

# Distinct delays per path make the routing observable in RTT as a second,
# independent signal alongside the counters.
bash "$TB/shaping/apply_shaping.sh" a down 50 10 0 3200 1000 >/dev/null 2>&1
bash "$TB/shaping/apply_shaping.sh" b down 50 40 0 3200 1000 >/dev/null 2>&1
echo "path A downlink delay = 10ms, path B downlink delay = 40ms"
echo

read_rx() {   # ns ifc -> rx packets
    ip netns exec "$1" cat "/sys/class/net/$2/statistics/rx_packets"
}

probe() {     # label  ping_args...
    local label=$1; shift
    local a0 b0 a1 b1
    a0=$(read_rx ns_bottle_a ba_c); b0=$(read_rx ns_bottle_b bb_c)
    local rtt
    rtt=$(ip netns exec ns_client ping -c 4 -q "$@" 10.0.9.1 2>/dev/null | tail -1)
    a1=$(read_rx ns_bottle_a ba_c); b1=$(read_rx ns_bottle_b bb_c)
    printf "  %-28s pathA_rx=%-4s pathB_rx=%-4s\n" "$label" "$((a1-a0))" "$((b1-b0))"
    printf "  %-28s %s\n" "" "$rtt"
}

echo "--- routing isolation ---"
probe "unbound (no -I)"
probe "bound to 10.0.1.1 (A)"  -I 10.0.1.1
probe "bound to 10.0.3.1 (B)"  -I 10.0.3.1

echo
echo "EXPECTED: unbound -> path A only (~10ms); bound A -> path A only (~10ms);"
echo "          bound B -> path B ONLY (~40ms). Any path-B traffic appearing on"
echo "          path A counters means the fallback route captured it."

bash "$TB/topology/teardown_topology.sh" >/dev/null 2>&1 && echo && echo "teardown clean"
