#!/usr/bin/env bash
# 10_smoke_custom_client.sh -- loopback smoke test of the custom migrate_client
set -uo pipefail

WORK=/home/sivaa/pvseed/_build/smoke3
rm -rf "$WORK"
mkdir -p "$WORK/webroot" "$WORK/qlog_server" "$WORK/qlog_client" "$WORK/downloads"

cd /home/sivaa/pvseed/picoquic/build

echo "=== generating 16MB test file ==="
dd if=/dev/zero of="$WORK/webroot/bigfile.bin" bs=1M count=16 status=none

echo "=== starting server (stock picoquicdemo) ==="
./picoquicdemo -p 4433 -c ../certs/cert.pem -k ../certs/key.pem -w "$WORK/webroot" \
    -q "$WORK/qlog_server" -l "$WORK/server.log" > "$WORK/server_stdout.log" 2>&1 &
SERVER_PID=$!
sleep 1

echo "=== starting custom migrate_client: -f 3, migrate to 127.0.0.2 after 1s ==="
PVSEED_MIGRATE_IP=127.0.0.2 PVSEED_MIGRATE_AFTER_US=30000 \
timeout 30 /home/sivaa/pvseed/harness/migrate_client -G newreno -f 3 -q "$WORK/qlog_client" \
    -o "$WORK/downloads" -l "$WORK/client.log" -n localhost -a hq-interop \
    127.0.0.1 4433 "bigfile.bin" > "$WORK/client_stdout.log" 2>&1
echo "client exit code: $?"

sleep 1
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true

echo "=== client stdout (full) ==="
cat "$WORK/client_stdout.log"

echo ""
echo "=== downloaded file check ==="
ls -la "$WORK/downloads" 2>&1

echo ""
echo "=== qlog files ==="
find "$WORK/qlog_client" "$WORK/qlog_server" -type f
