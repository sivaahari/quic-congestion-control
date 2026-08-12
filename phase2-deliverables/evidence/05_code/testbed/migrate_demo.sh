#!/usr/bin/env bash
# migrate_demo.sh
#
# Phase 1 / Task 3 -- demonstrate ONE controlled, IP-changing, client-initiated
# QUIC connection migration using picoquic, and capture qlog from both
# endpoints so the congestion-window / RTT behaviour around the migration
# instant can be analyzed offline.
#
# In ONE self-contained invocation this script:
#   1. Sets up the existing dual-path topology (testbed/topology/setup_topology.sh
#      -- NOT modified).
#   2. Shapes the DOWNLOAD direction of both paths (testbed/shaping/apply_shaping.sh
#      -- NOT modified): path A 50 Mbit/20 ms, path B 50 Mbit/40 ms, burst 3200,
#      so the two paths are distinguishable by RTT.
#   3. Starts a stock `picoquicdemo` server in ns_server, bound to the stable
#      service address 10.0.9.1.
#   4. Runs a CUSTOM client, `harness/migrate_client` (a copy of picoquic's own
#      picoquicdemo.c with a small, isolated timing/target-address tweak to
#      its EXISTING "-f 3" migration path -- see harness/migrate_client.c for
#      the exact diff-equivalent commentary), in ns_client. The client:
#        - starts on 10.0.1.1 (path A) -- this happens NATURALLY, with no
#          special flag, because ns_client's main-table fallback route sends
#          any unbound-source socket via path A (see setup_topology.sh finding 1).
#        - downloads a 64 MB file from the server.
#        - PVSEED_MIGRATE_AFTER_US after the connection reaches the "ready"
#          state, calls picoquic_probe_new_path() to migrate to 10.0.3.1
#          (path B), keeping the SAME UDP port, so the ONLY variable that
#          changes is the IP address -- never the port alone.
#   5. Captures qlog from BOTH client and server into
#      /home/sivaa/pvseed/results/raw/_migrate_demo/{qlog_client,qlog_server}/.
#   6. Tears down the topology.
#
# This script does not implement or modify any congestion-control or
# PV-Seed mechanism code; it only drives the existing picoquic stack for
# baseline characterization.
#
# Usage: migrate_demo.sh

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration (single source of truth -- no magic literals below)
# ---------------------------------------------------------------------------
TB=/home/sivaa/pvseed/testbed
PQ_BUILD=/home/sivaa/pvseed/picoquic/build
CERT=/home/sivaa/pvseed/picoquic/certs/cert.pem
KEY=/home/sivaa/pvseed/picoquic/certs/key.pem
MIGRATE_CLIENT=/home/sivaa/pvseed/harness/migrate_client

SERVICE_IP=10.0.9.1
SERVER_PORT=4433
CLIENT_TARGET_IP=10.0.3.1      # path B -- the client migrates TO here

RATE_MBIT=50
DELAY_A_MS=20
DELAY_B_MS=40
LOSS_PCT=0
BURST_BYTES=3200
LIMIT_PKTS=1000

FILE_SIZE_MB=64
CC_ALGO=newreno                # clean, predictable step-function cwnd for analysis
MIGRATE_AFTER_US=4000000       # 4s into the transfer (well before completion)
CLIENT_TIMEOUT_S=90
SNI=pvseed.test
ALPN=hq-interop

RESULTS=/home/sivaa/pvseed/results/raw/_migrate_demo
WEBROOT="$RESULTS/webroot"
DOWNLOADS="$RESULTS/downloads"
QLOG_SERVER="$RESULTS/qlog_server"
QLOG_CLIENT="$RESULTS/qlog_client"

log()  { printf '[migrate_demo] %s\n' "$*" >&2; }
die()  { printf '[migrate_demo][FATAL] %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
[ -x "$PQ_BUILD/picoquicdemo" ] || die "picoquicdemo not found/executable at $PQ_BUILD/picoquicdemo"
[ -x "$MIGRATE_CLIENT" ] || die "migrate_client not found/executable at $MIGRATE_CLIENT"
[ -f "$CERT" ] || die "cert not found at $CERT"
[ -f "$KEY" ] || die "key not found at $KEY"

# ---------------------------------------------------------------------------
# Fresh, self-contained results area
# ---------------------------------------------------------------------------
rm -rf "$RESULTS"
mkdir -p "$WEBROOT" "$DOWNLOADS" "$QLOG_SERVER" "$QLOG_CLIENT" \
    || die "could not create results directories under $RESULTS"

# ---------------------------------------------------------------------------
# Teardown must ALWAYS run, even on failure -- register it up front.
# (set -uo pipefail, deliberately WITHOUT -e, per project convention: we
# check exit codes explicitly at each important step instead.)
# ---------------------------------------------------------------------------
SERVER_PID=""
cleanup() {
    log "cleanup: stopping server (if running) and tearing down topology"
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        # Give the server (-1 flag) a chance to exit ON ITS OWN once it has
        # finished the one connection, so it finalizes the qlog file cleanly
        # instead of being SIGTERM'd mid-write (which leaves truncated JSON).
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
# 3. Test file -- tens of MB, content-agnostic (congestion behavior does not
#    depend on file content, /dev/zero is much faster to generate than
#    /dev/urandom for 64 MB).
# ---------------------------------------------------------------------------
log "generating ${FILE_SIZE_MB}MB test file"
dd if=/dev/zero of="$WEBROOT/bigfile.bin" bs=1M count="$FILE_SIZE_MB" status=none
[ -f "$WEBROOT/bigfile.bin" ] || die "failed to create test file"

# ---------------------------------------------------------------------------
# 4. Server, in ns_server, bound to the stable service address.
# ---------------------------------------------------------------------------
log "starting picoquicdemo server in ns_server on ${SERVICE_IP}:${SERVER_PORT}"
# -1: close the server after processing exactly one connection, so it exits
# CLEANLY (rather than being SIGTERM'd) and properly finalizes/closes the
# qlog file -- a killed process can leave the qlog JSON truncated.
ip netns exec ns_server "$PQ_BUILD/picoquicdemo" \
    -p "$SERVER_PORT" -c "$CERT" -k "$KEY" -w "$WEBROOT" \
    -q "$QLOG_SERVER" -l "$RESULTS/server.log" -1 \
    > "$RESULTS/server_stdout.log" 2>&1 &
SERVER_PID=$!
sleep 1
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    cat "$RESULTS/server_stdout.log" >&2
    die "server process died immediately after start; see $RESULTS/server_stdout.log"
fi
log "server pid=$SERVER_PID"

# ---------------------------------------------------------------------------
# 5. Client, in ns_client. Starts unbound (-> path A, 10.0.1.1, via the
#    main-table fallback route) and migrates to CLIENT_TARGET_IP (path B)
#    PVSEED_MIGRATE_AFTER_US into the transfer, same port, real IP change.
# ---------------------------------------------------------------------------
log "starting migrate_client in ns_client: cc=${CC_ALGO}, migrate to ${CLIENT_TARGET_IP} after ${MIGRATE_AFTER_US}us"
ip netns exec ns_client env \
    PVSEED_MIGRATE_IP="$CLIENT_TARGET_IP" \
    PVSEED_MIGRATE_AFTER_US="$MIGRATE_AFTER_US" \
    timeout "$CLIENT_TIMEOUT_S" "$MIGRATE_CLIENT" \
    -G "$CC_ALGO" -f 3 -q "$QLOG_CLIENT" -o "$DOWNLOADS" \
    -l "$RESULTS/client.log" -n "$SNI" -a "$ALPN" \
    "$SERVICE_IP" "$SERVER_PORT" "bigfile.bin" \
    > "$RESULTS/client_stdout.log" 2>&1
CLIENT_RC=$?
log "client exited with code $CLIENT_RC"

# ---------------------------------------------------------------------------
# 6. Quick pass/fail summary (teardown happens automatically via the trap).
# ---------------------------------------------------------------------------
DOWNLOADED_SIZE=$(stat -c%s "$DOWNLOADS/bigfile.bin" 2>/dev/null || echo 0)
EXPECTED_SIZE=$((FILE_SIZE_MB * 1024 * 1024))

log "downloaded file size: ${DOWNLOADED_SIZE} bytes (expected ${EXPECTED_SIZE})"
if [ "$DOWNLOADED_SIZE" -eq "$EXPECTED_SIZE" ]; then
    log "TRANSFER OK"
else
    log "TRANSFER INCOMPLETE OR MISSING -- check $RESULTS/client_stdout.log"
fi

if grep -q "\[pvseed\] Requesting migration:" "$RESULTS/client_stdout.log"; then
    log "MIGRATION TRIGGER FIRED (see client_stdout.log for details)"
else
    log "MIGRATION TRIGGER DID NOT FIRE -- check $RESULTS/client_stdout.log"
fi

log "qlog files:"
find "$QLOG_CLIENT" "$QLOG_SERVER" -type f >&2

log "done. Results in $RESULTS"
exit "$CLIENT_RC"
