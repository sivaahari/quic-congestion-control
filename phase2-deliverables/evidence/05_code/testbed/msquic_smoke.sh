#!/bin/bash
# msquic_smoke.sh -- loopback (no netns, no migration) sanity check that
# mq_server/mq_client can complete a basic handshake + small download before
# trusting the full netns+migration scenario. Mirrors quicgo_smoke.sh /
# quiche_smoke.sh's role in this survey.
set -uo pipefail

BIN=/home/sivaa/pvseed/harness/msquic/bin
CERT=/home/sivaa/pvseed/harness/quicgo/certs/cert.pem
KEY=/home/sivaa/pvseed/harness/quicgo/certs/key.pem
OUT=/home/sivaa/pvseed/results/raw/msquic/smoke
rm -rf "$OUT"; mkdir -p "$OUT"

log() { printf '[msquic_smoke] %s\n' "$*" >&2; }

dd if=/dev/urandom of="$OUT/small.bin" bs=1K count=512 status=none
log "test file: $(stat -c%s "$OUT/small.bin") bytes"

"$BIN/mq_server" --listen 127.0.0.1:5433 --cert "$CERT" --key "$KEY" \
    --file "$OUT/small.bin" --timeout-s 15 --idle-timeout-ms 5000 \
    > "$OUT/server.log" 2>&1 &
SERVER_PID=$!
sleep 0.5
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    log "server died immediately"
    cat "$OUT/server.log"
    exit 1
fi

timeout 20 "$BIN/mq_client" --server-addr 127.0.0.1:5433 \
    --local-a 127.0.0.1:0 --local-b 127.0.0.1:0 --migrate-after-ms 999999 \
    --sni pvseed.test --out "$OUT/downloaded.bin" --timeout-s 15 \
    > "$OUT/client.log" 2>&1
CLIENT_RC=$?
log "client exit code: $CLIENT_RC"

wait "$SERVER_PID" 2>/dev/null
SERVER_RC=$?
log "server exit code: $SERVER_RC"

if cmp -s "$OUT/small.bin" "$OUT/downloaded.bin"; then
    log "CONTENT VERIFIED (byte-for-byte match)"
    CONTENT_OK=1
else
    log "CONTENT MISMATCH or missing -- see $OUT"
    CONTENT_OK=0
fi

log "server.log: $(wc -l < "$OUT/server.log") lines, client.log: $(wc -l < "$OUT/client.log") lines"
log "=== server.log (our markers only; full firehose is in the file) ==="
grep '^\[mq_server\]' "$OUT/server.log"
log "=== client.log (our markers only; full firehose is in the file) ==="
grep '^\[mq_client\]' "$OUT/client.log"

[ "$CONTENT_OK" -eq 1 ] && [ "$CLIENT_RC" -eq 0 ]
exit $?
