#!/usr/bin/env bash
# apply_shaping.sh
#
# Applies per-direction rate/delay/loss shaping to one bottleneck's egress
# interface for one direction of one path, using a two-stage qdisc chain:
#
#   root (handle 1:)  tbf    -- enforces capacity (rate/burst/limit)
#   child (handle 10:) netem -- enforces delay/loss
#
# Capacity limiting is deliberately isolated in the tbf stage and jitter/
# delay/loss in the netem stage so the chain is inspectable stage-by-stage
# with `tc qdisc show` / `tc -s qdisc show`.
#
# Usage:
#   apply_shaping.sh <path: a|b> <direction: down|up> <rate_mbit> <delay_ms> <loss_pct> <burst_bytes> <limit_pkts>
#
#   path         a | b     which bottleneck namespace to shape in
#   direction    down|up   down = server->client, up = client->server
#   rate_mbit    tbf token-bucket rate in Mbit/s (decimal SI: 1 mbit = 1e6 bit/s)
#   delay_ms     netem one-way delay to add, milliseconds
#   loss_pct     netem random-loss percentage, 0-100 (may be fractional)
#   burst_bytes  tbf burst / token-bucket depth, in bytes. THIS is the
#                parameter the Phase-0 calibration exists to characterize:
#                if burst_bytes >= (train_length * packet_size), an entire
#                back-to-back probe train passes through at line rate,
#                UNSHAPED, and you measure the bucket, not the link.
#   limit_pkts   tbf queue limit, expressed in PACKETS for operator
#                convenience. Converted to the bytes tc actually wants via
#                the target interface's live MTU (limit_bytes = limit_pkts * mtu),
#                so no packet-size constant is hardcoded in this script.
#
# Re-appliable: any existing root qdisc on the target interface is deleted
# (errors ignored) before the new chain is built.

set -euo pipefail

usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") <path: a|b> <direction: down|up> <rate_mbit> <delay_ms> <loss_pct> <burst_bytes> <limit_pkts>

  path         a | b            which bottleneck namespace (ns_bottle_a / ns_bottle_b)
  direction    down | up        down = server->client (shape ba_c/bb_c egress)
                                 up   = client->server (shape ba_s/bb_s egress)
  rate_mbit    tbf rate in Mbit/s, e.g. 20
  delay_ms     netem one-way delay in ms, e.g. 10
  loss_pct     netem loss percentage, e.g. 0 or 0.5
  burst_bytes  tbf burst (token bucket depth) in bytes, e.g. 3200
  limit_pkts   tbf queue limit in packets (converted to bytes via live MTU)
EOF
    exit 1
}

log() { printf '[apply_shaping] %s\n' "$*" >&2; }
die() { printf '[apply_shaping][FATAL] %s\n' "$*" >&2; exit 1; }

[ "$#" -eq 7 ] || usage

PATH_ID=$1
DIRECTION=$2
RATE_MBIT=$3
DELAY_MS=$4
LOSS_PCT=$5
BURST_BYTES=$6
LIMIT_PKTS=$7

is_nonneg_num() { [[ $1 =~ ^[0-9]+([.][0-9]+)?$ ]]; }
is_nonneg_int() { [[ $1 =~ ^[0-9]+$ ]]; }

is_nonneg_num "$RATE_MBIT"   || die "rate_mbit must be a non-negative number, got: $RATE_MBIT"
is_nonneg_num "$DELAY_MS"    || die "delay_ms must be a non-negative number, got: $DELAY_MS"
is_nonneg_num "$LOSS_PCT"    || die "loss_pct must be a non-negative number, got: $LOSS_PCT"
is_nonneg_int "$BURST_BYTES" || die "burst_bytes must be a non-negative integer, got: $BURST_BYTES"
is_nonneg_int "$LIMIT_PKTS"  || die "limit_pkts must be a non-negative integer, got: $LIMIT_PKTS"

case "$PATH_ID" in
    a) BOTTLE_NS=ns_bottle_a ;;
    b) BOTTLE_NS=ns_bottle_b ;;
    *) die "path must be 'a' or 'b', got: $PATH_ID" ;;
esac

case "$DIRECTION" in
    down)
        case "$PATH_ID" in
            a) IFC=ba_c ;;
            b) IFC=bb_c ;;
        esac
        ;;
    up)
        case "$PATH_ID" in
            a) IFC=ba_s ;;
            b) IFC=bb_s ;;
        esac
        ;;
    *) die "direction must be 'down' or 'up', got: $DIRECTION" ;;
esac

ip netns list | awk '{print $1}' | grep -qx "$BOTTLE_NS" \
    || die "namespace $BOTTLE_NS does not exist -- run setup_topology.sh first"
ip -n "$BOTTLE_NS" link show "$IFC" >/dev/null 2>&1 \
    || die "interface $IFC not found in $BOTTLE_NS -- run setup_topology.sh first"

MTU=$(ip netns exec "$BOTTLE_NS" cat "/sys/class/net/${IFC}/mtu")
[ -n "$MTU" ] && [ "$MTU" -gt 0 ] || die "could not read a valid MTU for $IFC in $BOTTLE_NS"
LIMIT_BYTES=$(( LIMIT_PKTS * MTU ))

log "target: path=$PATH_ID direction=$DIRECTION ns=$BOTTLE_NS ifc=$IFC mtu=$MTU"

# Re-appliable: tear down any existing root qdisc first (fine if none exists).
ip netns exec "$BOTTLE_NS" tc qdisc del dev "$IFC" root >/dev/null 2>&1 || true

# --- root: tbf enforces capacity ---
ip netns exec "$BOTTLE_NS" tc qdisc add dev "$IFC" root handle 1: tbf \
    rate "${RATE_MBIT}mbit" burst "${BURST_BYTES}" limit "${LIMIT_BYTES}"

# --- child: netem enforces delay/loss ---
ip netns exec "$BOTTLE_NS" tc qdisc add dev "$IFC" parent 1: handle 10: netem \
    delay "${DELAY_MS}ms" loss "${LOSS_PCT}%"

log "applied: rate=${RATE_MBIT}mbit burst=${BURST_BYTES}B limit=${LIMIT_PKTS}pkts(=${LIMIT_BYTES}B @ mtu ${MTU}) delay=${DELAY_MS}ms loss=${LOSS_PCT}%"
log "tc qdisc show dev $IFC (netns $BOTTLE_NS):"
ip netns exec "$BOTTLE_NS" tc qdisc show dev "$IFC"
