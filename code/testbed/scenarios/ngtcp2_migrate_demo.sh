#!/usr/bin/env bash
# ngtcp2 migration trial.
#
# ngtcp2's example client exposes --change-local-addr=<DURATION>, but it does
# not let you name the target address: change_local_addr() (examples/client.cc
# :1305) opens a new socket and asks the ROUTING TABLE which local address
# reaches the server (get_local_addr(remote_addr_) -> bind_addr). In this
# testbed that would return path A again, i.e. a port-only change -- which
# RFC 9000 s9.4 explicitly exempts from the reset, so it would not exercise Q1.
#
# So we drive it the way a real handover does: flip ns_client's main-table
# route from path A to path B a moment before the client's timer fires. The
# client then genuinely binds 10.0.3.1 and migrates to a different IP.
#
# Usage: OUT_DIR=<dir> [MIGRATE_AFTER_S=5] bash ngtcp2_migrate_demo.sh
set -uo pipefail

P=/home/sivaa/pvseed
TB=$P/testbed
BIN=$P/ngtcp2/build/examples
OUT_DIR=${OUT_DIR:?set OUT_DIR}
MIGRATE_AFTER_S=${MIGRATE_AFTER_S:-5}
FILE_MB=${FILE_MB:-40}
RATE_MBIT=${RATE_MBIT:-20}
DELAY_A_MS=${DELAY_A_MS:-20}
DELAY_B_MS=${DELAY_B_MS:-40}

mkdir -p "$OUT_DIR"/{qlog_client,qlog_server}
CERTS=$P/harness/ngtcp2/certs
mkdir -p "$CERTS"

cleanup() {
    pkill -f "ptlsserve[r]" 2>/dev/null
    pkill -f "ptlsclien[t]" 2>/dev/null
    bash "$TB/topology/teardown_topology.sh" >"$OUT_DIR/teardown.log" 2>&1
}
trap cleanup EXIT

# --- certs (once) ---
if [ ! -f "$CERTS/server.key" ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$CERTS/server.key" -out "$CERTS/server.crt" \
        -subj "/CN=pvseed.test" \
        -addext "subjectAltName=IP:10.0.9.1,DNS:pvseed.test" \
        >/dev/null 2>&1
fi

# --- topology + shaping ---
bash "$TB/topology/setup_topology.sh" >"$OUT_DIR/setup.log" 2>&1 || { echo "SETUP FAILED"; exit 1; }
bash "$TB/shaping/apply_shaping.sh" a down "$RATE_MBIT" "$DELAY_A_MS" 0 3200 1000 >"$OUT_DIR/shaping_a.log" 2>&1
bash "$TB/shaping/apply_shaping.sh" b down "$RATE_MBIT" "$DELAY_B_MS" 0 3200 1000 >"$OUT_DIR/shaping_b.log" 2>&1

# --- payload ---
WEB=$OUT_DIR/webroot; mkdir -p "$WEB"
[ -f "$WEB/bigfile.bin" ] || head -c $((FILE_MB * 1024 * 1024)) /dev/urandom > "$WEB/bigfile.bin"

# --- server ---
ip netns exec ns_server "$BIN/ptlsserver" 10.0.9.1 4433 \
    "$CERTS/server.key" "$CERTS/server.crt" \
    --qlog-dir "$OUT_DIR/qlog_server" -d "$WEB" \
    > "$OUT_DIR/server.log" 2>&1 &
SRV=$!
sleep 1.5

# --- route flipper: switch the default path just before the client migrates ---
(
    sleep "$(echo "$MIGRATE_AFTER_S - 0.25" | bc)"
    ip netns exec ns_client ip route replace 10.0.9.1 via 10.0.3.2 dev cli_b
    echo "[flip] main route -> path B (10.0.3.2) at $(date +%s.%N)"
) > "$OUT_DIR/flip.log" 2>&1 &
FLIP=$!

# --- client ---
ip netns exec ns_client "$BIN/ptlsclient" 10.0.9.1 4433 \
    "https://pvseed.test/bigfile.bin" \
    --change-local-addr "${MIGRATE_AFTER_S}s" \
    --qlog-dir "$OUT_DIR/qlog_client" \
    --download "$OUT_DIR" \
    --exit-on-all-streams-close \
    > "$OUT_DIR/client.log" 2>&1
echo "client exit=$?" | tee -a "$OUT_DIR/client.log"

wait $FLIP 2>/dev/null
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

# --- restore route for the next rep ---
ip netns exec ns_client ip route replace 10.0.9.1 via 10.0.1.2 dev cli_a 2>/dev/null

echo "--- local address change reported by the client ---"
grep -iE "Changing local address|Local address is now" "$OUT_DIR/client.log" | head -4
echo "--- qlog files ---"
ls -la "$OUT_DIR/qlog_server" "$OUT_DIR/qlog_client" 2>/dev/null | grep -c sqlog || true
