#!/usr/bin/env bash
# setup_topology.sh
#
# Builds the Phase-0 dual-path QUIC-handover emulation topology:
#
#   ns_client                ns_bottle_a                 ns_server
#    cli_a 10.0.1.1/24 <---> ba_c 10.0.1.2/24
#                            ba_s 10.0.2.1/24 <--------> srv_a 10.0.2.2/24
#    cli_b 10.0.3.1/24 <---> bb_c 10.0.3.2/24
#                            bb_s 10.0.4.1/24 <--------> srv_b 10.0.4.2/24
#                 (ns_bottle_b holds bb_c and bb_s)
#
# ns_server additionally owns a stable service address 10.0.9.1/32 on a
# dummy0 interface, reachable from ns_client via EITHER path A or path B.
# This models QUIC connection migration: the server's address never
# changes; only the client's egress path does.
#
# ns_client routing has two layers (see step 6 below for the full
# rationale): source-based policy rules select path A/B deterministically
# for any socket that explicitly binds CLI_A_IP/CLI_B_IP, and a main-table
# fallback route makes UNBOUND sockets default to path A instead of
# failing with ENETUNREACH (Phase-0 audit FINDING 1).
#
# Idempotent: always tears down first, so re-running is safe.
#
# Usage: setup_topology.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Naming / addressing plan (single source of truth -- no magic literals below)
# ---------------------------------------------------------------------------
NS_CLIENT=ns_client
NS_BOTTLE_A=ns_bottle_a
NS_BOTTLE_B=ns_bottle_b
NS_SERVER=ns_server

PREFIX=24

CLI_A_IF=cli_a;  CLI_A_IP=10.0.1.1
BA_C_IF=ba_c;    BA_C_IP=10.0.1.2
BA_S_IF=ba_s;    BA_S_IP=10.0.2.1
SRV_A_IF=srv_a;  SRV_A_IP=10.0.2.2

CLI_B_IF=cli_b;  CLI_B_IP=10.0.3.1
BB_C_IF=bb_c;    BB_C_IP=10.0.3.2
BB_S_IF=bb_s;    BB_S_IP=10.0.4.1
SRV_B_IF=srv_b;  SRV_B_IP=10.0.4.2

SERVICE_IF=dummy0
SERVICE_IP=10.0.9.1

TABLE_A=101
TABLE_B=102
RULE_PRIO_A=100
RULE_PRIO_B=200

MTU=1500

log()  { printf '[setup] %s\n' "$*" >&2; }
die()  { printf '[setup][FATAL] %s\n' "$*" >&2; exit 1; }

# Small helper so the rest of the script reads declaratively.
nsx() { local ns=$1; shift; ip netns exec "$ns" "$@"; }

# ---------------------------------------------------------------------------
# 0. Idempotency: tear down any previous instance of the topology first.
# ---------------------------------------------------------------------------
log "tearing down any pre-existing topology"
"$SCRIPT_DIR/teardown_topology.sh"

# ---------------------------------------------------------------------------
# 1. Create namespaces and harden each one BEFORE any interface exists in it,
#    so that new interfaces inherit rp_filter=0 / ipv6-disabled from the
#    namespace's "default" settings rather than racing against them.
# ---------------------------------------------------------------------------
for ns in "$NS_CLIENT" "$NS_BOTTLE_A" "$NS_BOTTLE_B" "$NS_SERVER"; do
    log "creating namespace $ns"
    ip netns add "$ns"
    nsx "$ns" ip link set lo up
    nsx "$ns" sysctl -qw net.ipv4.conf.all.rp_filter=0
    nsx "$ns" sysctl -qw net.ipv4.conf.default.rp_filter=0
    nsx "$ns" sysctl -qw net.ipv6.conf.all.disable_ipv6=1
    nsx "$ns" sysctl -qw net.ipv6.conf.default.disable_ipv6=1
done

# ---------------------------------------------------------------------------
# 2. Create veth pairs in the root namespace and shuffle each end into place.
# ---------------------------------------------------------------------------
log "creating veth pair $CLI_A_IF <-> $BA_C_IF (path A, client side)"
ip link add "$CLI_A_IF" type veth peer name "$BA_C_IF"
ip link set "$CLI_A_IF" netns "$NS_CLIENT"
ip link set "$BA_C_IF"  netns "$NS_BOTTLE_A"

log "creating veth pair $BA_S_IF <-> $SRV_A_IF (path A, server side)"
ip link add "$BA_S_IF" type veth peer name "$SRV_A_IF"
ip link set "$BA_S_IF"  netns "$NS_BOTTLE_A"
ip link set "$SRV_A_IF" netns "$NS_SERVER"

log "creating veth pair $CLI_B_IF <-> $BB_C_IF (path B, client side)"
ip link add "$CLI_B_IF" type veth peer name "$BB_C_IF"
ip link set "$CLI_B_IF" netns "$NS_CLIENT"
ip link set "$BB_C_IF"  netns "$NS_BOTTLE_B"

log "creating veth pair $BB_S_IF <-> $SRV_B_IF (path B, server side)"
ip link add "$BB_S_IF" type veth peer name "$SRV_B_IF"
ip link set "$BB_S_IF"  netns "$NS_BOTTLE_B"
ip link set "$SRV_B_IF" netns "$NS_SERVER"

# ---------------------------------------------------------------------------
# 3. Per-interface hardening (belt-and-suspenders on top of the namespace
#    defaults set in step 1), addressing, mtu, and bring-up.
# ---------------------------------------------------------------------------
harden_iface() {
    local ns=$1 ifc=$2
    nsx "$ns" sysctl -qw "net.ipv4.conf.${ifc}.rp_filter=0"
    nsx "$ns" sysctl -qw "net.ipv6.conf.${ifc}.disable_ipv6=1"
}

configure_iface() {
    local ns=$1 ifc=$2 ip=$3 prefix=$4
    harden_iface "$ns" "$ifc"
    ip -n "$ns" addr add "${ip}/${prefix}" dev "$ifc"
    ip -n "$ns" link set "$ifc" mtu "$MTU"
    ip -n "$ns" link set "$ifc" up
}

log "configuring $NS_CLIENT interfaces"
configure_iface "$NS_CLIENT" "$CLI_A_IF" "$CLI_A_IP" "$PREFIX"
configure_iface "$NS_CLIENT" "$CLI_B_IF" "$CLI_B_IP" "$PREFIX"

log "configuring $NS_BOTTLE_A interfaces"
configure_iface "$NS_BOTTLE_A" "$BA_C_IF" "$BA_C_IP" "$PREFIX"
configure_iface "$NS_BOTTLE_A" "$BA_S_IF" "$BA_S_IP" "$PREFIX"

log "configuring $NS_BOTTLE_B interfaces"
configure_iface "$NS_BOTTLE_B" "$BB_C_IF" "$BB_C_IP" "$PREFIX"
configure_iface "$NS_BOTTLE_B" "$BB_S_IF" "$BB_S_IP" "$PREFIX"

log "configuring $NS_SERVER interfaces"
configure_iface "$NS_SERVER" "$SRV_A_IF" "$SRV_A_IP" "$PREFIX"
configure_iface "$NS_SERVER" "$SRV_B_IF" "$SRV_B_IP" "$PREFIX"

# ---------------------------------------------------------------------------
# 4. ns_server's stable service address on a dummy interface.
# ---------------------------------------------------------------------------
log "creating $SERVICE_IF ($SERVICE_IP/32) in $NS_SERVER"
ip -n "$NS_SERVER" link add "$SERVICE_IF" type dummy
harden_iface "$NS_SERVER" "$SERVICE_IF"
ip -n "$NS_SERVER" addr add "${SERVICE_IP}/32" dev "$SERVICE_IF"
ip -n "$NS_SERVER" link set "$SERVICE_IF" up

# ---------------------------------------------------------------------------
# 5. Enable forwarding on both bottlenecks only.
# ---------------------------------------------------------------------------
log "enabling ip_forward on $NS_BOTTLE_A and $NS_BOTTLE_B"
nsx "$NS_BOTTLE_A" sysctl -qw net.ipv4.ip_forward=1
nsx "$NS_BOTTLE_B" sysctl -qw net.ipv4.ip_forward=1

# ---------------------------------------------------------------------------
# 6. Routing.
# ---------------------------------------------------------------------------

# ns_client: source-based policy routing so BOTH paths are usable at once
# (required for make-before-break handovers). Table A / B each carry a
# connected-subnet route (so the nexthop below resolves) plus a host route
# to the server's service address via that path's bottleneck.
log "configuring source-based routing in $NS_CLIENT"
ip -n "$NS_CLIENT" rule add from "$CLI_A_IP" table "$TABLE_A" priority "$RULE_PRIO_A"
ip -n "$NS_CLIENT" rule add from "$CLI_B_IP" table "$TABLE_B" priority "$RULE_PRIO_B"

ip -n "$NS_CLIENT" route add "10.0.1.0/${PREFIX}" dev "$CLI_A_IF" src "$CLI_A_IP" table "$TABLE_A"
ip -n "$NS_CLIENT" route add "${SERVICE_IP}/32" via "$BA_C_IP" dev "$CLI_A_IF" table "$TABLE_A"

ip -n "$NS_CLIENT" route add "10.0.3.0/${PREFIX}" dev "$CLI_B_IF" src "$CLI_B_IP" table "$TABLE_B"
ip -n "$NS_CLIENT" route add "${SERVICE_IP}/32" via "$BB_C_IP" dev "$CLI_B_IF" table "$TABLE_B"

# --- FINDING 1 fix: fallback route for UNBOUND sockets in the MAIN table ---
#
# The two `ip rule from <addr> table <N>` rules above only fire once a
# packet's source address is already fixed to CLI_A_IP or CLI_B_IP -- e.g. a
# socket that called bind() explicitly, or a reply on an already-accepted
# connection (whose local address was fixed at accept time). A brand-new
# socket that connects WITHOUT binding a source first performs its initial
# route lookup with source address unset, which cannot match either "from"
# rule (both require an exact source match); that lookup falls through to
# the kernel's default "from all lookup main" rule (priority 32766, below
# both RULE_PRIO_A=100 and RULE_PRIO_B=200, i.e. evaluated LAST). Until now
# the main table had NO route to SERVICE_IP at all, so that fallback lookup
# failed outright -- ENETUNREACH -- which silently hung any test that used
# an unbound socket (Phase-0 audit FINDING 1).
#
# Fix: add a plain route (no "table" argument => the main table) to
# SERVICE_IP via path A. This does not touch or shadow the source-based
# rules: a rule with a lower priority NUMBER is evaluated FIRST, so an
# explicitly-bound socket (source already = CLI_A_IP or CLI_B_IP when the
# lookup runs) still matches its own "from" rule before the main table is
# ever consulted, and therefore still selects its path deterministically.
# Net effect of this one extra route:
#   * unbound socket                       -> main table matches -> path A
#   * socket explicitly bound to CLI_A_IP  -> rule prio 100 matches first -> path A (unchanged)
#   * socket explicitly bound to CLI_B_IP  -> rule prio 200 matches first -> path B (unchanged)
log "configuring main-table fallback route in $NS_CLIENT (unbound sockets default to path A)"
ip -n "$NS_CLIENT" route add "${SERVICE_IP}/32" via "$BA_C_IP" dev "$CLI_A_IF" src "$CLI_A_IP"

# ns_bottle_a / ns_bottle_b: forward towards the service address via the
# server-facing veth. Return-direction routes back to the client subnets
# already exist as kernel-installed connected routes on the client-facing
# veth, so nothing extra is needed there.
log "configuring forwarding route in $NS_BOTTLE_A"
ip -n "$NS_BOTTLE_A" route add "${SERVICE_IP}/32" via "$SRV_A_IP" dev "$BA_S_IF"

log "configuring forwarding route in $NS_BOTTLE_B"
ip -n "$NS_BOTTLE_B" route add "${SERVICE_IP}/32" via "$SRV_B_IP" dev "$BB_S_IF"

# ns_server: explicit return routes to each client source address via the
# correct bottleneck (the client subnets are not directly connected to the
# server, so these are required, not just an optimization).
log "configuring return routes in $NS_SERVER"
ip -n "$NS_SERVER" route add "${CLI_A_IP}/32" via "$BA_S_IP" dev "$SRV_A_IF"
ip -n "$NS_SERVER" route add "${CLI_B_IP}/32" via "$BB_S_IP" dev "$SRV_B_IF"

# ---------------------------------------------------------------------------
# 7. Verification: ping the service address from ns_client via EACH source
#    address / path. Fail loudly if either path cannot reach the server.
# ---------------------------------------------------------------------------
log "verifying path A: ping ${SERVICE_IP} from ${CLI_A_IP}"
if nsx "$NS_CLIENT" ping -c 3 -W 2 -I "$CLI_A_IP" "$SERVICE_IP" >/tmp/ping_a.$$.log 2>&1; then
    log "path A OK"
    sed 's/^/[setup][ping-a] /' /tmp/ping_a.$$.log >&2
else
    sed 's/^/[setup][ping-a] /' /tmp/ping_a.$$.log >&2
    rm -f /tmp/ping_a.$$.log
    die "path A (source $CLI_A_IP via $NS_BOTTLE_A) CANNOT reach $SERVICE_IP"
fi
rm -f /tmp/ping_a.$$.log

log "verifying path B: ping ${SERVICE_IP} from ${CLI_B_IP}"
if nsx "$NS_CLIENT" ping -c 3 -W 2 -I "$CLI_B_IP" "$SERVICE_IP" >/tmp/ping_b.$$.log 2>&1; then
    log "path B OK"
    sed 's/^/[setup][ping-b] /' /tmp/ping_b.$$.log >&2
else
    sed 's/^/[setup][ping-b] /' /tmp/ping_b.$$.log >&2
    rm -f /tmp/ping_b.$$.log
    die "path B (source $CLI_B_IP via $NS_BOTTLE_B) CANNOT reach $SERVICE_IP"
fi
rm -f /tmp/ping_b.$$.log

log "verifying unbound (no -I) path: ping ${SERVICE_IP} using the main-table fallback route"
if nsx "$NS_CLIENT" ping -c 3 -W 2 "$SERVICE_IP" >/tmp/ping_unbound.$$.log 2>&1; then
    log "unbound path OK (FINDING 1 fallback route working)"
    sed 's/^/[setup][ping-unbound] /' /tmp/ping_unbound.$$.log >&2
else
    sed 's/^/[setup][ping-unbound] /' /tmp/ping_unbound.$$.log >&2
    rm -f /tmp/ping_unbound.$$.log
    die "unbound socket (no source bind) CANNOT reach $SERVICE_IP -- main-table fallback route is broken"
fi
rm -f /tmp/ping_unbound.$$.log

log "topology up: both paths (A via $NS_BOTTLE_A, B via $NS_BOTTLE_B) reach $SERVICE_IP; unbound sockets default to path A"
