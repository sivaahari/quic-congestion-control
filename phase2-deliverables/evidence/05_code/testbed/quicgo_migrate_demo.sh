#!/usr/bin/env bash
# quicgo_migrate_demo.sh
#
# PV-Seed Phase 2 -- demonstrate ONE controlled, IP-changing,
# CLIENT-INITIATED QUIC connection migration using quic-go (the SECOND
# implementation in the cross-implementation survey; picoquic was Phase 1),
# and capture qlog from both endpoints so the congestion-window / RTT
# behaviour around the migration instant can be analyzed offline. This is
# the quic-go analogue of testbed/scenarios/migrate_demo.sh.
#
# In ONE self-contained invocation this script:
#   1. Sets up the existing dual-path topology (testbed/topology/setup_topology.sh
#      -- NOT modified).
#   2. Shapes the DOWNLOAD direction of both paths (testbed/shaping/apply_shaping.sh
#      -- NOT modified): path A 20 Mbit/20 ms, path B 20 Mbit/40 ms, burst 3200
#      (calibrated), so the two paths are distinguishable by RTT and the
#      transfer runs long enough (~15-20s) for a mid-transfer migration.
#   3. Starts harness/quicgo/bin/qgserver in ns_server, bound to the stable
#      service address 10.0.9.1, qlog enabled via QLOGDIR.
#   4. Runs harness/quicgo/bin/qgclient in ns_client:
#        - binds explicitly to 10.0.1.1 (path A) for the initial connection
#          (source-based routing requires an explicit bind; see
#          testbed/topology/setup_topology.sh finding 1).
#        - downloads the test file over one QUIC stream.
#        - MIGRATE_AFTER_S into the transfer, calls the public
#          quic-go migration API (Conn.AddPath -> Path.Probe -> Path.Switch,
#          path_manager_outgoing.go) to migrate to 10.0.3.1 (path B), same
#          UDP port semantics as picoquic's harness (a NEW local socket is
#          bound; the port is whatever the kernel assigns on that new
#          address, matching how a real client migrating to a new NIC/
#          network would behave).
#   5. Captures qlog from BOTH client and server into
#      /home/sivaa/pvseed/results/raw/quicgo/migrate_demo/{qlog_client,qlog_server}/.
#   6. Tears down the topology.
#
# This script does not modify quic-go source; it only drives the stock
# public API for baseline characterization, exactly as migrate_demo.sh
# drives stock picoquicdemo.
#
# Usage: quicgo_migrate_demo.sh

set -uo pipefail

TB=/home/sivaa/pvseed/testbed
QG_BIN=/home/sivaa/pvseed/harness/quicgo/bin
CERT=/home/sivaa/pvseed/harness/quicgo/certs/cert.pem
KEY=/home/sivaa/pvseed/harness/quicgo/certs/key.pem

SERVICE_IP=10.0.9.1
SERVER_PORT=4433
CLI_A_IP=10.0.1.1     # path A -- client starts here
CLI_B_IP=10.0.3.1     # path B -- client migrates TO here

RATE_MBIT=20
DELAY_A_MS=20
DELAY_B_MS=40
LOSS_PCT=0
BURST_BYTES=3200      # calibrated -- do not change without re-running testbed/calibration/
LIMIT_PKTS=1000

FILE_SIZE_MB=40        # at 20 Mbit/s down, ideal ~16s -- long enough for a ~5s-in migration
MIGRATE_AFTER=5s
CLIENT_TIMEOUT=90s
SERVER_IDLE_TIMEOUT=30s
SNI=pvseed.test

RESULTS=/home/sivaa/pvseed/results/raw/quicgo/migrate_demo
WEBROOT="$RESULTS/webroot"
QLOG_SERVER="$RESULTS/qlog_server"
QLOG_CLIENT="$RESULTS/qlog_client"

log()  { printf '[quicgo_migrate_demo] %s\n' "$*" >&2; }
die()  { printf '[quicgo_migrate_demo][FATAL] %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
[ -x "$QG_BIN/qgserver" ] || die "qgserver not found/executable at $QG_BIN/qgserver"
[ -x "$QG_BIN/qgclient" ] || die "qgclient not found/executable at $QG_BIN/qgclient"
[ -f "$CERT" ] || die "cert not found at $CERT"
[ -f "$KEY" ] || die "key not found at $KEY"

# ---------------------------------------------------------------------------
# Fresh, self-contained results area
# ---------------------------------------------------------------------------
rm -rf "$RESULTS"
mkdir -p "$WEBROOT" "$QLOG_SERVER" "$QLOG_CLIENT" \
    || die "could not create results directories under $RESULTS"

# ---------------------------------------------------------------------------
# Teardown must ALWAYS run, even on failure.
# (set -uo pipefail, deliberately WITHOUT -e, per project convention: exit
# codes are checked explicitly at each important step instead.)
# ---------------------------------------------------------------------------
SERVER_PID=""
cleanup() {
    log "cleanup: stopping server (if running) and tearing down topology"
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        for _ in $(seq 1 20); do
            kill -0 "$SERVER_PID" 2>/dev/null || break
            sleep 0.5
        done
        if kill -0 "$SERVER_PID" 2>/dev/null; then
            log "server still running after grace period, sending SIGTERM"
            kill "$SERVER_PID" >/dev/null 2>&1 || true
        fi
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    bash "$TB/topology/teardown_topology.sh" >>"$RESULTS/teardown.log" 2>&1
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Topology
# ---------------------------------------------------------------------------
log "setting up topology"
bash "$TB/topology/setup_topology.sh" >"$RESULTS/setup.log" 2>&1
SETUP_RC=$?
[ "$SETUP_RC" -eq 0 ] || die "setup_topology.sh failed (rc=$SETUP_RC); see $RESULTS/setup.log"

# ---------------------------------------------------------------------------
# 2. Shaping -- download direction of both paths, distinguishable by RTT.
# ---------------------------------------------------------------------------
log "shaping path A: down ${RATE_MBIT}mbit / ${DELAY_A_MS}ms / ${LOSS_PCT}% loss, burst=${BURST_BYTES}"
bash "$TB/shaping/apply_shaping.sh" a down "$RATE_MBIT" "$DELAY_A_MS" "$LOSS_PCT" "$BURST_BYTES" "$LIMIT_PKTS" \
    >"$RESULTS/shaping_a.log" 2>&1
[ $? -eq 0 ] || die "apply_shaping.sh (path A) failed; see $RESULTS/shaping_a.log"

log "shaping path B: down ${RATE_MBIT}mbit / ${DELAY_B_MS}ms / ${LOSS_PCT}% loss, burst=${BURST_BYTES}"
bash "$TB/shaping/apply_shaping.sh" b down "$RATE_MBIT" "$DELAY_B_MS" "$LOSS_PCT" "$BURST_BYTES" "$LIMIT_PKTS" \
    >"$RESULTS/shaping_b.log" 2>&1
[ $? -eq 0 ] || die "apply_shaping.sh (path B) failed; see $RESULTS/shaping_b.log"

# ---------------------------------------------------------------------------
# 3. Test file
# ---------------------------------------------------------------------------
log "generating ${FILE_SIZE_MB}MB test file"
dd if=/dev/zero of="$WEBROOT/bigfile.bin" bs=1M count="$FILE_SIZE_MB" status=none
[ -f "$WEBROOT/bigfile.bin" ] || die "failed to create test file"

# ---------------------------------------------------------------------------
# 4. Server, in ns_server, bound to the stable service address.
# ---------------------------------------------------------------------------
log "starting qgserver in ns_server on ${SERVICE_IP}:${SERVER_PORT}"
ip netns exec ns_server env QLOGDIR="$QLOG_SERVER" "$QG_BIN/qgserver" \
    -addr "${SERVICE_IP}:${SERVER_PORT}" \
    -cert "$CERT" -key "$KEY" \
    -file "$WEBROOT/bigfile.bin" \
    -idle-timeout "$SERVER_IDLE_TIMEOUT" \
    > "$RESULTS/server_stdout.log" 2>&1 &
SERVER_PID=$!
sleep 1
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    cat "$RESULTS/server_stdout.log" >&2
    die "server process died immediately after start; see $RESULTS/server_stdout.log"
fi
log "server pid=$SERVER_PID"

# ---------------------------------------------------------------------------
# 5. Client, in ns_client. Starts bound to CLI_A_IP (path A) and migrates to
#    CLI_B_IP (path B) MIGRATE_AFTER into the transfer, real IP change.
# ---------------------------------------------------------------------------
log "starting qgclient in ns_client: migrate ${CLI_A_IP} -> ${CLI_B_IP} after ${MIGRATE_AFTER}"
ip netns exec ns_client env QLOGDIR="$QLOG_CLIENT" \
    timeout 100 "$QG_BIN/qgclient" \
    -server-addr "${SERVICE_IP}:${SERVER_PORT}" \
    -local-a "${CLI_A_IP}:0" \
    -local-b "${CLI_B_IP}:0" \
    -migrate-after "$MIGRATE_AFTER" \
    -ca "$CERT" \
    -sni "$SNI" \
    -out "$RESULTS/downloaded.bin" \
    -timeout "$CLIENT_TIMEOUT" \
    > "$RESULTS/client_stdout.log" 2>&1
CLIENT_RC=$?
log "client exited with code $CLIENT_RC"

# ---------------------------------------------------------------------------
# 6. Quick pass/fail summary (teardown happens automatically via the trap).
# ---------------------------------------------------------------------------
DOWNLOADED_SIZE=$(stat -c%s "$RESULTS/downloaded.bin" 2>/dev/null || echo 0)
EXPECTED_SIZE=$((FILE_SIZE_MB * 1024 * 1024))

log "downloaded file size: ${DOWNLOADED_SIZE} bytes (expected ${EXPECTED_SIZE})"
if [ "$DOWNLOADED_SIZE" -eq "$EXPECTED_SIZE" ]; then
    log "TRANSFER OK"
    if cmp -s "$WEBROOT/bigfile.bin" "$RESULTS/downloaded.bin"; then
        log "TRANSFER CONTENT VERIFIED (byte-for-byte match)"
    else
        log "TRANSFER SIZE OK BUT CONTENT MISMATCH -- investigate"
    fi
else
    log "TRANSFER INCOMPLETE OR MISSING -- check $RESULTS/client_stdout.log"
fi

if grep -q "MIGRATE_CUTOVER_CONFIRMED" "$RESULTS/client_stdout.log"; then
    log "MIGRATION CONFIRMED (local address change observed)"
    grep "MIGRATE_" "$RESULTS/client_stdout.log" >&2
else
    log "MIGRATION NOT CONFIRMED -- check $RESULTS/client_stdout.log"
fi

log "qlog files:"
find "$QLOG_CLIENT" "$QLOG_SERVER" -type f >&2

log "done. Results in $RESULTS"
exit "$CLIENT_RC"
