#!/usr/bin/env bash
# teardown_topology.sh
#
# Removes the four-namespace dual-path QUIC handover emulation topology.
# Safe to run repeatedly and safe to run when nothing exists yet: every
# removal is guarded by an existence check so this script never errors out
# because "there was nothing to delete".
#
# Usage: teardown_topology.sh

set -euo pipefail

NAMESPACES=(ns_client ns_bottle_a ns_bottle_b ns_server)
# veth ends that could conceivably be left dangling in the root namespace if
# a previous run died between "ip link add" and "ip link set netns ...".
STRAY_IFACES=(cli_a ba_c ba_s srv_a cli_b bb_c bb_s srv_b)

log() { printf '[teardown] %s\n' "$*" >&2; }

for ns in "${NAMESPACES[@]}"; do
    if ip netns list | awk '{print $1}' | grep -qx "$ns"; then
        ip netns del "$ns"
        log "deleted namespace $ns"
    else
        log "namespace $ns not present, skipping"
    fi
done

for dev in "${STRAY_IFACES[@]}"; do
    if ip link show "$dev" >/dev/null 2>&1; then
        ip link del "$dev" >/dev/null 2>&1 || true
        log "deleted stray root-namespace interface $dev"
    fi
done

log "complete"
