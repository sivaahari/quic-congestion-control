#!/usr/bin/env bash
# quiche_migrate_demo.sh
#
# PV-Seed Phase 2 -- demonstrate REPEATED, controlled, IP-changing,
# CLIENT-INITIATED QUIC connection migrations using quiche (Cloudflare,
# Rust; the THIRD implementation in the cross-implementation survey after
# picoquic and quic-go), capturing qlog from both endpoints so cwnd/RTT
# behaviour around the migration instant can be analyzed. Analogue of
# testbed/scenarios/quicgo_migrate_demo.sh, with two deliberate differences
# learned from that script's own documented gotcha:
#   1. Takes an OUTPUT DIRECTORY as $1 (not hardcoded), so different
#      invocations do not collide.
#   2. Runs REPS repetitions (default 5) in ONE topology
#      setup/teardown, and PARSES each repetition's qlogs into a CSV +
#      text summary immediately after that repetition finishes and BEFORE
#      the next one starts, so a later repetition can never overwrite an
#      earlier one's raw qlogs before they have been reduced to CSV.
#
# Shaping parameters are IDENTICAL to quicgo_migrate_demo.sh (20 Mbit both
# paths, 20ms path A / 40ms path B, burst=3200 calibrated, 0% loss) so the
# three implementations are being compared under the same network
# conditions.
#
# Usage: quiche_migrate_demo.sh [OUTDIR] [REPS]
#   OUTDIR default: /home/sivaa/pvseed/results/raw/quiche/migrate_demo
#   REPS   default: 5

set -uo pipefail

TB=/home/sivaa/pvseed/testbed
QC_BIN=/home/sivaa/pvseed/harness/quiche/target/release
CERT=/home/sivaa/pvseed/harness/quicgo/certs/cert.pem
KEY=/home/sivaa/pvseed/harness/quicgo/certs/key.pem
PARSER=/home/sivaa/pvseed/analysis/parse_qlog_quiche.py

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

FILE_SIZE_MB=40         # at 20 Mbit/s down, ideal ~16s -- long enough for a ~5s-in migration
MIGRATE_AFTER_MS=5000
CLIENT_TIMEOUT_S=90
SERVER_TIMEOUT_S=100
SERVER_IDLE_TIMEOUT_MS=30000
SNI=pvseed.test

OUTDIR="${1:-/home/sivaa/pvseed/results/raw/quiche/migrate_demo}"
REPS="${2:-5}"

log()  { printf '[quiche_migrate_demo] %s\n' "$*" >&2; }
die()  { printf '[quiche_migrate_demo][FATAL] %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
[ -x "$QC_BIN/qcserver" ] || die "qcserver not found/executable at $QC_BIN/qcserver"
[ -x "$QC_BIN/qcclient" ] || die "qcclient not found/executable at $QC_BIN/qcclient"
[ -f "$CERT" ] || die "cert not found at $CERT"
[ -f "$KEY" ] || die "key not found at $KEY"
[ -f "$PARSER" ] || die "parser not found at $PARSER"

# ---------------------------------------------------------------------------
# Fresh, self-contained results area
# ---------------------------------------------------------------------------
rm -rf "$OUTDIR"
WEBROOT="$OUTDIR/webroot"
mkdir -p "$WEBROOT" || die "could not create $WEBROOT"

# ---------------------------------------------------------------------------
# Teardown must ALWAYS run, even on failure.
# ---------------------------------------------------------------------------
cleanup() {
    log "cleanup: tearing down topology"
    bash "$TB/topology/teardown_topology.sh" >>"$OUTDIR/teardown.log" 2>&1
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Topology (once for all repetitions)
# ---------------------------------------------------------------------------
log "setting up topology"
bash "$TB/topology/setup_topology.sh" >"$OUTDIR/setup.log" 2>&1
SETUP_RC=$?
[ "$SETUP_RC" -eq 0 ] || die "setup_topology.sh failed (rc=$SETUP_RC); see $OUTDIR/setup.log"

# ---------------------------------------------------------------------------
# 2. Shaping (once for all repetitions) -- download direction of both paths.
# ---------------------------------------------------------------------------
log "shaping path A: down ${RATE_MBIT}mbit / ${DELAY_A_MS}ms / ${LOSS_PCT}% loss, burst=${BURST_BYTES}"
bash "$TB/shaping/apply_shaping.sh" a down "$RATE_MBIT" "$DELAY_A_MS" "$LOSS_PCT" "$BURST_BYTES" "$LIMIT_PKTS" \
    >"$OUTDIR/shaping_a.log" 2>&1
[ $? -eq 0 ] || die "apply_shaping.sh (path A) failed; see $OUTDIR/shaping_a.log"

log "shaping path B: down ${RATE_MBIT}mbit / ${DELAY_B_MS}ms / ${LOSS_PCT}% loss, burst=${BURST_BYTES}"
bash "$TB/shaping/apply_shaping.sh" b down "$RATE_MBIT" "$DELAY_B_MS" "$LOSS_PCT" "$BURST_BYTES" "$LIMIT_PKTS" \
    >"$OUTDIR/shaping_b.log" 2>&1
[ $? -eq 0 ] || die "apply_shaping.sh (path B) failed; see $OUTDIR/shaping_b.log"

# ---------------------------------------------------------------------------
# 3. Test file (shared across all repetitions)
# ---------------------------------------------------------------------------
log "generating ${FILE_SIZE_MB}MB test file"
dd if=/dev/urandom of="$WEBROOT/bigfile.bin" bs=1M count="$FILE_SIZE_MB" status=none
[ -f "$WEBROOT/bigfile.bin" ] || die "failed to create test file"

# ---------------------------------------------------------------------------
# 4. Repetitions: server up, client migrates, both torn down, PARSE, repeat.
# ---------------------------------------------------------------------------
PASS_COUNT=0
RESET_COUNT=0

for REP in $(seq 1 "$REPS"); do
    RDIR="$OUTDIR/rep_$REP"
    QLOG_SERVER="$RDIR/qlog_server"
    QLOG_CLIENT="$RDIR/qlog_client"
    mkdir -p "$QLOG_SERVER" "$QLOG_CLIENT"

    log "=== repetition $REP/$REPS ==="

    ip netns exec ns_server env QLOGDIR="$QLOG_SERVER" "$QC_BIN/qcserver" \
        --listen "${SERVICE_IP}:${SERVER_PORT}" \
        --cert "$CERT" --key "$KEY" \
        --file "$WEBROOT/bigfile.bin" \
        --idle-timeout-ms "$SERVER_IDLE_TIMEOUT_MS" \
        --timeout-s "$SERVER_TIMEOUT_S" \
        > "$RDIR/server_stdout.log" 2>"$RDIR/server_stderr.log" &
    SERVER_PID=$!
    sleep 0.5
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        log "rep $REP: server died immediately, see $RDIR/server_stderr.log"
        cat "$RDIR/server_stderr.log" >&2
        continue
    fi

    ip netns exec ns_client env QLOGDIR="$QLOG_CLIENT" \
        timeout "$((CLIENT_TIMEOUT_S + 10))" "$QC_BIN/qcclient" \
        --server-addr "${SERVICE_IP}:${SERVER_PORT}" \
        --local-a "${CLI_A_IP}:0" \
        --local-b "${CLI_B_IP}:0" \
        --migrate-after-ms "$MIGRATE_AFTER_MS" \
        --ca "$CERT" \
        --sni "$SNI" \
        --out "$RDIR/downloaded.bin" \
        --timeout-s "$CLIENT_TIMEOUT_S" \
        > "$RDIR/client_stdout.log" 2>"$RDIR/client_stderr.log"
    CLIENT_RC=$?
    log "rep $REP: client exited with code $CLIENT_RC"

    # Give the server a moment to observe the close and exit on its own.
    for _ in $(seq 1 20); do
        kill -0 "$SERVER_PID" 2>/dev/null || break
        sleep 0.5
    done
    if kill -0 "$SERVER_PID" 2>/dev/null; then
        log "rep $REP: server still running after grace period, sending SIGTERM"
        kill "$SERVER_PID" >/dev/null 2>&1 || true
    fi
    wait "$SERVER_PID" 2>/dev/null || true

    DOWNLOADED_SIZE=$(stat -c%s "$RDIR/downloaded.bin" 2>/dev/null || echo 0)
    EXPECTED_SIZE=$((FILE_SIZE_MB * 1024 * 1024))
    CONTENT_OK=0
    if [ "$DOWNLOADED_SIZE" -eq "$EXPECTED_SIZE" ] && cmp -s "$WEBROOT/bigfile.bin" "$RDIR/downloaded.bin"; then
        CONTENT_OK=1
        log "rep $REP: TRANSFER CONTENT VERIFIED ($DOWNLOADED_SIZE bytes)"
    else
        log "rep $REP: TRANSFER INCOMPLETE OR CONTENT MISMATCH (got $DOWNLOADED_SIZE, want $EXPECTED_SIZE)"
    fi
    # Downloaded payload no longer needed once verified -- delete now so a
    # failed later repetition's disk usage does not compound across REPS
    # (qlogs, which are what analysis actually needs, are kept).
    rm -f "$RDIR/downloaded.bin"

    MIGRATION_OK=0
    if grep -q "MIGRATE_CUTOVER_CONFIRMED" "$RDIR/client_stderr.log"; then
        MIGRATION_OK=1
        log "rep $REP: MIGRATION CONFIRMED"
    else
        log "rep $REP: MIGRATION NOT CONFIRMED"
    fi

    SERVER_ACCEPT_OK=0
    if grep -q "PeerMigrated" "$RDIR/server_stderr.log"; then
        SERVER_ACCEPT_OK=1
        log "rep $REP: SERVER observed PeerMigrated"
    else
        log "rep $REP: SERVER did NOT observe PeerMigrated"
    fi

    # ------------------------------------------------------------------
    # PARSE NOW, before the next repetition starts (this is why REPS lives
    # inside one script: raw qlogs are reduced to CSV+summary immediately,
    # so nothing from repetition N+1 can ever clobber unparsed data from N).
    # ------------------------------------------------------------------
    SERVER_QLOG=$(find "$QLOG_SERVER" -name '*.sqlog' 2>/dev/null | head -1)
    CLIENT_QLOG=$(find "$QLOG_CLIENT" -name '*.sqlog' 2>/dev/null | head -1)

    if [ -n "$SERVER_QLOG" ]; then
        python3 "$PARSER" --qlog "$SERVER_QLOG" \
            --label arm=migrate_demo --label role=server --label rep="$REP" \
            --csv "$RDIR/server_metrics.csv" --summary \
            > "$RDIR/server_summary.txt" 2>&1
        log "rep $REP: server qlog parsed -> $RDIR/server_metrics.csv"
    else
        log "rep $REP: WARNING no server qlog found under $QLOG_SERVER"
    fi

    if [ -n "$CLIENT_QLOG" ]; then
        python3 "$PARSER" --qlog "$CLIENT_QLOG" \
            --label arm=migrate_demo --label role=client --label rep="$REP" \
            --csv "$RDIR/client_metrics.csv" --summary \
            > "$RDIR/client_summary.txt" 2>&1
        log "rep $REP: client qlog parsed -> $RDIR/client_metrics.csv"
    fi

    if [ -f "$RDIR/server_summary.txt" ] && grep -q "RESET-CONSISTENT" "$RDIR/server_summary.txt"; then
        RESET_COUNT=$((RESET_COUNT + 1))
    fi

    if [ "$CONTENT_OK" -eq 1 ] && [ "$MIGRATION_OK" -eq 1 ] && [ "$SERVER_ACCEPT_OK" -eq 1 ]; then
        PASS_COUNT=$((PASS_COUNT + 1))
    fi

    echo "rep=$REP content_ok=$CONTENT_OK migration_ok=$MIGRATION_OK server_accept_ok=$SERVER_ACCEPT_OK" >> "$OUTDIR/rep_status.txt"
done

log "=== summary: $PASS_COUNT/$REPS repetitions fully passed (content+migration+server-accept), $RESET_COUNT/$REPS showed a cwnd reset to CWIN_INITIAL on the server ==="
log "done. Results in $OUTDIR"

[ "$PASS_COUNT" -eq "$REPS" ]
exit $?
