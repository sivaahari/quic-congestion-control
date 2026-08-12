#!/bin/bash
set -uo pipefail
export PATH=/usr/local/go/bin:$PATH
BIN=/home/sivaa/pvseed/harness/quicgo/bin
CERTDIR=/home/sivaa/pvseed/harness/quicgo/certs
RESULTS=/home/sivaa/pvseed/results/raw/quicgo/_smoke
rm -rf "$RESULTS"
mkdir -p "$RESULTS/webroot" "$RESULTS/qlog_client" "$RESULTS/qlog_server"

log() { printf '[smoke] %s\n' "$*" >&2; }

# 2 MiB test file -- fast, loopback only, just to validate the programs work.
dd if=/dev/zero of="$RESULTS/webroot/bigfile.bin" bs=1M count=200 status=none

log "starting server on 127.0.0.1:5555"
QLOGDIR="$RESULTS/qlog_server" "$BIN/qgserver" \
    -addr 127.0.0.1:5555 \
    -cert "$CERTDIR/cert.pem" -key "$CERTDIR/key.pem" \
    -file "$RESULTS/webroot/bigfile.bin" \
    -idle-timeout 10s \
    > "$RESULTS/server_stdout.log" 2>&1 &
SERVER_PID=$!
sleep 1
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    log "server died immediately"
    cat "$RESULTS/server_stdout.log" >&2
    exit 1
fi

log "starting client, migrate 127.0.0.1 -> 127.0.0.2 after 1s"
QLOGDIR="$RESULTS/qlog_client" timeout 30 "$BIN/qgclient" \
    -server-addr 127.0.0.1:5555 \
    -local-a 127.0.0.1:0 \
    -local-b 127.0.0.2:0 \
    -migrate-after 1s \
    -ca "$CERTDIR/cert.pem" \
    -sni pvseed.test \
    -out "$RESULTS/downloaded.bin" \
    -timeout 25s \
    > "$RESULTS/client_stdout.log" 2>&1
CLIENT_RC=$?
log "client exited rc=$CLIENT_RC"

wait "$SERVER_PID" 2>/dev/null
log "server exited"

echo "=== client_stdout.log ==="
cat "$RESULTS/client_stdout.log"
echo "=== server_stdout.log ==="
cat "$RESULTS/server_stdout.log"
echo "=== file check ==="
ls -la "$RESULTS/webroot/bigfile.bin" "$RESULTS/downloaded.bin" 2>&1
cmp "$RESULTS/webroot/bigfile.bin" "$RESULTS/downloaded.bin" && echo "FILES MATCH" || echo "FILES DIFFER"
echo "=== qlog files ==="
find "$RESULTS/qlog_client" "$RESULTS/qlog_server" -type f -exec ls -la {} \;
echo "SMOKE_TEST_RC=$CLIENT_RC"
