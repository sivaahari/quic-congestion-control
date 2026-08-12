#!/usr/bin/env bash
# quiche_smoke.sh -- fast local smoke test of qcserver/qcclient (no netns,
# no tc shaping) to catch harness bugs cheaply before running the full
# testbed scenario. Uses 127.0.0.1 (path A) and 127.0.0.2 (path B, a
# loopback alias) so a real local-address change still occurs.
set -uo pipefail

BIN=/home/sivaa/pvseed/harness/quiche/target/release
CERT=/home/sivaa/pvseed/harness/quicgo/certs/cert.pem
KEY=/home/sivaa/pvseed/harness/quicgo/certs/key.pem

RESULTS=/home/sivaa/pvseed/results/raw/quiche/smoke
rm -rf "$RESULTS"
mkdir -p "$RESULTS/qlog_client" "$RESULTS/qlog_server"

log() { printf '[smoke] %s\n' "$*" >&2; }

# loopback alias for path B
ip addr add 127.0.0.2/8 dev lo 2>/dev/null || true
ip link set lo up

dd if=/dev/urandom of="$RESULTS/testfile.bin" bs=1M count=20 status=none
log "test file: $(stat -c%s "$RESULTS/testfile.bin") bytes"

SERVER_PID=""
cleanup() {
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

QLOGDIR="$RESULTS/qlog_server" "$BIN/qcserver" \
    --listen 127.0.0.1:5599 \
    --cert "$CERT" --key "$KEY" \
    --file "$RESULTS/testfile.bin" \
    --idle-timeout-ms 10000 \
    --timeout-s 30 \
    > "$RESULTS/server_stdout.log" 2>"$RESULTS/server_stderr.log" &
SERVER_PID=$!
sleep 0.3
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    log "FATAL: server died immediately"
    cat "$RESULTS/server_stderr.log" >&2
    exit 1
fi
log "server pid=$SERVER_PID"

QLOGDIR="$RESULTS/qlog_client" "$BIN/qcclient" \
    --server-addr 127.0.0.1:5599 \
    --local-a 127.0.0.1:0 \
    --local-b 127.0.0.2:0 \
    --migrate-after-ms 2 \
    --ca "$CERT" \
    --sni pvseed.test \
    --out "$RESULTS/downloaded.bin" \
    --timeout-s 20 \
    > "$RESULTS/client_stdout.log" 2>"$RESULTS/client_stderr.log"
CLIENT_RC=$?
log "client exit code: $CLIENT_RC"

sleep 0.5

log "=== client stderr (tail) ==="
tail -60 "$RESULTS/client_stderr.log" >&2
log "=== server stderr (tail) ==="
tail -60 "$RESULTS/server_stderr.log" >&2

DOWNLOADED_SIZE=$(stat -c%s "$RESULTS/downloaded.bin" 2>/dev/null || echo 0)
ORIG_SIZE=$(stat -c%s "$RESULTS/testfile.bin")
log "downloaded=$DOWNLOADED_SIZE orig=$ORIG_SIZE"
if [ "$DOWNLOADED_SIZE" -eq "$ORIG_SIZE" ] && cmp -s "$RESULTS/testfile.bin" "$RESULTS/downloaded.bin"; then
    log "CONTENT_VERIFIED_OK"
else
    log "CONTENT_MISMATCH_OR_INCOMPLETE"
fi

if grep -q "MIGRATE_CUTOVER_CONFIRMED" "$RESULTS/client_stderr.log"; then
    log "MIGRATION_CONFIRMED"
else
    log "MIGRATION_NOT_CONFIRMED"
fi

log "qlog files:"
find "$RESULTS/qlog_client" "$RESULTS/qlog_server" -type f >&2

log "done"
