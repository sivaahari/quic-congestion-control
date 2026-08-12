#!/usr/bin/env bash
# quiche_diag_run1.sh -- ONE focused diagnostic repetition with
# QCCLIENT_DEBUG_READABLE=1 to see what conn.readable() reports after the
# post-migration stall observed in quiche_migrate_demo.sh.
set -uo pipefail

TB=/home/sivaa/pvseed/testbed
QC_BIN=/home/sivaa/pvseed/harness/quiche/target/release
CERT=/home/sivaa/pvseed/harness/quicgo/certs/cert.pem
KEY=/home/sivaa/pvseed/harness/quicgo/certs/key.pem

SERVICE_IP=10.0.9.1
SERVER_PORT=4433
CLI_A_IP=10.0.1.1
CLI_B_IP=10.0.3.1

OUTDIR=/home/sivaa/pvseed/results/raw/quiche/diag_run1
rm -rf "$OUTDIR"
WEBROOT="$OUTDIR/webroot"
mkdir -p "$WEBROOT" "$OUTDIR/qlog_server" "$OUTDIR/qlog_client"

log() { printf '[diag_run1] %s\n' "$*" >&2; }

cleanup() {
    bash "$TB/topology/teardown_topology.sh" >>"$OUTDIR/teardown.log" 2>&1
}
trap cleanup EXIT

bash "$TB/topology/setup_topology.sh" >"$OUTDIR/setup.log" 2>&1 || { log "setup failed"; exit 1; }
bash "$TB/shaping/apply_shaping.sh" a down 20 20 0 3200 1000 >"$OUTDIR/shaping_a.log" 2>&1
bash "$TB/shaping/apply_shaping.sh" b down 20 40 0 3200 1000 >"$OUTDIR/shaping_b.log" 2>&1

dd if=/dev/urandom of="$WEBROOT/bigfile.bin" bs=1M count=40 status=none

ip netns exec ns_server env QLOGDIR="$OUTDIR/qlog_server" "$QC_BIN/qcserver" \
    --listen "${SERVICE_IP}:${SERVER_PORT}" \
    --cert "$CERT" --key "$KEY" \
    --file "$WEBROOT/bigfile.bin" \
    --idle-timeout-ms 30000 \
    --timeout-s 40 \
    > "$OUTDIR/server_stdout.log" 2>"$OUTDIR/server_stderr.log" &
SERVER_PID=$!
sleep 0.5

ip netns exec ns_client env QLOGDIR="$OUTDIR/qlog_client" QCCLIENT_DEBUG_READABLE=1 \
    timeout 35 "$QC_BIN/qcclient" \
    --server-addr "${SERVICE_IP}:${SERVER_PORT}" \
    --local-a "${CLI_A_IP}:0" \
    --local-b "${CLI_B_IP}:0" \
    --migrate-after-ms 5000 \
    --ca "$CERT" \
    --sni pvseed.test \
    --out "$OUTDIR/downloaded.bin" \
    --timeout-s 30 \
    > "$OUTDIR/client_stdout.log" 2>"$OUTDIR/client_stderr.log"
log "client rc=$?"

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true

log "client stderr lines: $(wc -l < "$OUTDIR/client_stderr.log")"
log "done"
