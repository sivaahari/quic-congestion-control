#!/usr/bin/env bash
# msquic_migrate_demo.sh
#
# PV-Seed Phase 2 -- demonstrate REPEATED, controlled, IP-changing,
# CLIENT-INITIATED QUIC connection migrations using msquic (Microsoft, C;
# the FOURTH implementation in the cross-implementation survey after
# picoquic, quic-go and quiche), capturing congestion/RTT behaviour around
# the migration instant so it can be analyzed offline. Analogue of
# testbed/scenarios/quiche_migrate_demo.sh:
#   1. Takes an OUTPUT DIRECTORY as $1 (not hardcoded).
#   2. Runs REPS repetitions (default 5, task requires >=3) in ONE topology
#      setup/teardown, parsing each repetition's logs into a CSV + text
#      summary immediately after that repetition finishes and BEFORE the
#      next one starts (so a later repetition can never overwrite an
#      earlier one's unparsed logs).
#
# Shaping parameters are IDENTICAL to quicgo_migrate_demo.sh /
# quiche_migrate_demo.sh (20 Mbit both paths, 20ms path A / 40ms path B,
# burst=3200 calibrated, 0% loss) so all four implementations are compared
# under the same network conditions.
#
# INSTRUMENTATION: msquic has no native qlog on Linux (see the task report's
# "KNOWN RISK" section). This harness (harness/msquic/{server,client}.cpp)
# instead (a) polls QUIC_PARAM_CONN_STATISTICS_V2 every --stats-interval-ms
# for a quantitative cwnd/RTT time series, and (b) is built against msquic
# with -DQUIC_LOGGING_TYPE=stdout (_build/msquic_configure_build.sh) so
# msquic's own internal trace lines (e.g. the literal
# "Path[N] Set active (rebind=N)" decision) are ALSO on the same stdout --
# the qualitative cross-check. Both endpoints' raw stdout is piped through a
# grep filter at capture time (see LOG_FILTER below) to discard msquic's
# extremely high-volume per-packet/per-worker scheduling trace (which is not
# needed for analysis and would otherwise run into the hundreds of MB per
# rep for a real ~16s multi-Mbit transfer, as directly observed even in a
# 5-second loopback smoke test).
#
# Usage: msquic_migrate_demo.sh [OUTDIR] [REPS]
#   OUTDIR default: /home/sivaa/pvseed/results/raw/msquic/migrate_demo
#   REPS   default: 5

set -uo pipefail

TB=/home/sivaa/pvseed/testbed
MQ_BIN=/home/sivaa/pvseed/harness/msquic/bin
CERT=/home/sivaa/pvseed/harness/quicgo/certs/cert.pem
KEY=/home/sivaa/pvseed/harness/quicgo/certs/key.pem
PARSER=/home/sivaa/pvseed/analysis/parse_qlog_msquic.py

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

FILE_SIZE_MB=40          # at 20 Mbit/s down, ideal ~16s -- long enough for a ~5s-in migration
MIGRATE_AFTER_MS=5000
CLIENT_TIMEOUT_S=90
SERVER_TIMEOUT_S=100
SERVER_IDLE_TIMEOUT_MS=30000
STATS_INTERVAL_MS=5      # finer than the 20ms default -- better resolution around the migration instant
SNI=pvseed.test
ALPN=pvseed-msquic-survey

# Keeps our own MARKER/STATS lines (needed by the parser) plus a small,
# named set of msquic-internal trace lines relevant to migration/congestion
# (see analysis/parse_qlog_msquic.py's regexes, which this must stay in sync
# with), and drops msquic's high-volume scheduling/worker/api-enter-exit
# noise.
LOG_FILTER='^\[mq_(server|client)\]|Set active \(rebind=|Congestion event:|Persistent congestion event|STATS: SRtt=|New (Local|Remote) IP|HANDSHAKE_DONE'

OUTDIR="${1:-/home/sivaa/pvseed/results/raw/msquic/migrate_demo}"
REPS="${2:-5}"

log()  { printf '[msquic_migrate_demo] %s\n' "$*" >&2; }
die()  { printf '[msquic_migrate_demo][FATAL] %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
[ -x "$MQ_BIN/mq_server" ] || die "mq_server not found/executable at $MQ_BIN/mq_server"
[ -x "$MQ_BIN/mq_client" ] || die "mq_client not found/executable at $MQ_BIN/mq_client"
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
REBIND0_COUNT=0   # rebind=0 observed (real-change classification -> CC reset)
REBIND1_COUNT=0   # rebind=1 observed (port-only classification -> CC NOT reset)

for REP in $(seq 1 "$REPS"); do
    RDIR="$OUTDIR/rep_$REP"
    mkdir -p "$RDIR"

    log "=== repetition $REP/$REPS ==="

    # Both mq_server/mq_client write EVERYTHING (our own Logf lines AND
    # msquic's own QuicTraceEvent/QuicTraceLog* lines) to real stdout, not
    # stderr -- so it is stdout, not stderr, that must go through the
    # LOG_FILTER grep. Wrapped in a subshell so `exit "${PIPESTATUS[0]}"`
    # can propagate the ACTUAL binary's exit code (not grep's) out as the
    # subshell's own exit code -- `$!`/`$?` on a bare pipeline would
    # otherwise give grep's PID/status, not mq_server's/mq_client's.
    ( ip netns exec ns_server "$MQ_BIN/mq_server" \
        --listen "${SERVICE_IP}:${SERVER_PORT}" \
        --cert "$CERT" --key "$KEY" \
        --file "$WEBROOT/bigfile.bin" \
        --idle-timeout-ms "$SERVER_IDLE_TIMEOUT_MS" \
        --stats-interval-ms "$STATS_INTERVAL_MS" \
        --timeout-s "$SERVER_TIMEOUT_S" \
        --alpn "$ALPN" \
        2>"$RDIR/server_stderr.log" \
        | grep --line-buffered -E "$LOG_FILTER" > "$RDIR/server.log"
      exit "${PIPESTATUS[0]}" ) &
    SERVER_PID=$!
    sleep 0.5
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        log "rep $REP: server died immediately"
        continue
    fi

    ( ip netns exec ns_client \
        timeout "$((CLIENT_TIMEOUT_S + 10))" "$MQ_BIN/mq_client" \
        --server-addr "${SERVICE_IP}:${SERVER_PORT}" \
        --local-a "${CLI_A_IP}:0" \
        --local-b "${CLI_B_IP}:0" \
        --migrate-after-ms "$MIGRATE_AFTER_MS" \
        --stats-interval-ms "$STATS_INTERVAL_MS" \
        --sni "$SNI" --alpn "$ALPN" \
        --out "$RDIR/downloaded.bin" \
        --timeout-s "$CLIENT_TIMEOUT_S" \
        2>"$RDIR/client_stderr.log" \
        | grep --line-buffered -E "$LOG_FILTER" > "$RDIR/client.log"
      exit "${PIPESTATUS[0]}" )
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
    rm -f "$RDIR/downloaded.bin"

    MIGRATION_OK=0
    if grep -q "MIGRATE_CUTOVER_CONFIRMED" "$RDIR/client.log"; then
        MIGRATION_OK=1
        log "rep $REP: MIGRATION CONFIRMED (client)"
    else
        log "rep $REP: MIGRATION NOT CONFIRMED (client) -- check $RDIR/client.log"
    fi

    SERVER_ACCEPT_OK=0
    if grep -q "SERVER_PEER_ADDR_CHANGED" "$RDIR/server.log"; then
        SERVER_ACCEPT_OK=1
        log "rep $REP: SERVER observed SERVER_PEER_ADDR_CHANGED"
    else
        log "rep $REP: SERVER did NOT observe SERVER_PEER_ADDR_CHANGED -- check $RDIR/server.log"
    fi

    # ------------------------------------------------------------------
    # PARSE NOW, before the next repetition starts.
    # ------------------------------------------------------------------
    python3 "$PARSER" --log "$RDIR/server.log" \
        --label arm=migrate_demo --label role=server --label rep="$REP" \
        --csv "$RDIR/server_metrics.csv" --summary \
        > "$RDIR/server_summary.txt" 2>&1
    log "rep $REP: server log parsed -> $RDIR/server_metrics.csv"

    python3 "$PARSER" --log "$RDIR/client.log" \
        --label arm=migrate_demo --label role=client --label rep="$REP" \
        --csv "$RDIR/client_metrics.csv" --summary \
        > "$RDIR/client_summary.txt" 2>&1
    log "rep $REP: client log parsed -> $RDIR/client_metrics.csv"

    if grep -q "rebind=0" "$RDIR/server_summary.txt" 2>/dev/null; then
        REBIND0_COUNT=$((REBIND0_COUNT + 1))
    fi
    if grep -q "rebind=1" "$RDIR/server_summary.txt" 2>/dev/null; then
        REBIND1_COUNT=$((REBIND1_COUNT + 1))
    fi

    if [ "$CONTENT_OK" -eq 1 ] && [ "$MIGRATION_OK" -eq 1 ] && [ "$SERVER_ACCEPT_OK" -eq 1 ]; then
        PASS_COUNT=$((PASS_COUNT + 1))
    fi

    echo "rep=$REP content_ok=$CONTENT_OK migration_ok=$MIGRATION_OK server_accept_ok=$SERVER_ACCEPT_OK" >> "$OUTDIR/rep_status.txt"
done

log "=== summary: $PASS_COUNT/$REPS repetitions fully passed (content+migration+server-accept) ==="
log "=== server-side rebind classification: rebind=0 (real change, CC reset) in $REBIND0_COUNT/$REPS; rebind=1 (port-only, CC NOT reset) in $REBIND1_COUNT/$REPS ==="
log "done. Results in $OUTDIR"

[ "$PASS_COUNT" -eq "$REPS" ]
exit $?
