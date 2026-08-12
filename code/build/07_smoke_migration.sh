#!/usr/bin/env bash
# 07_smoke_migration.sh -- cheap loopback smoke test of the -A/-f flag
# combination for triggering a real local-address change, BEFORE committing
# to the full netns testbed. Not part of the final deliverable.
set -uo pipefail

WORK=/home/sivaa/pvseed/_build/smoke
rm -rf "$WORK"
mkdir -p "$WORK/webroot" "$WORK/qlog_server" "$WORK/qlog_client" "$WORK/downloads"

cd /home/sivaa/pvseed/picoquic/build

echo "=== generating 8MB test file ==="
dd if=/dev/zero of="$WORK/webroot/bigfile.bin" bs=1M count=8 status=none
ls -la "$WORK/webroot"

echo "=== checking 127.0.0.2 usable ==="
ping -c 1 -W 1 127.0.0.2 || echo "ping to 127.0.0.2 failed (may still work for UDP bind)"

echo "=== starting server ==="
./picoquicdemo -p 4433 -c ../certs/cert.pem -k ../certs/key.pem -w "$WORK/webroot" \
    -q "$WORK/qlog_server" -l "$WORK/server.log" > "$WORK/server_stdout.log" 2>&1 &
SERVER_PID=$!
sleep 1
echo "server pid=$SERVER_PID"

echo "=== starting client (newreno, -A 127.0.0.2/0, -f 2) ==="
timeout 30 ./picoquicdemo -G newreno -A "127.0.0.2/0" -f 2 -q "$WORK/qlog_client" \
    -o "$WORK/downloads" -l "$WORK/client.log" -n localhost -a hq-interop \
    127.0.0.1 4433 "bigfile.bin" > "$WORK/client_stdout.log" 2>&1
CLIENT_RC=$?
echo "client exit code: $CLIENT_RC"

sleep 1
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true

echo "=== client stdout (grep for migration/path/address keywords) ==="
grep -iE 'migrat|path|address|cnxid|error' "$WORK/client_stdout.log" | head -60

echo ""
echo "=== downloaded file check ==="
ls -la "$WORK/downloads" 2>&1

echo ""
echo "=== qlog files produced ==="
find "$WORK/qlog_client" "$WORK/qlog_server" -type f

echo ""
echo "=== full client stdout ==="
cat "$WORK/client_stdout.log"
