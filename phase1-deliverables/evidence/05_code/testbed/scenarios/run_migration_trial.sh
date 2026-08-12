#!/usr/bin/env bash
# run_migration_trial.sh
#
# Phase 1 / Tasks 1-3 -- reusable SINGLE-TRIAL driver for the PV-Seed
# migration baseline-characterization experiments.
#
# Unlike migrate_demo.sh (which owns topology setup/teardown for a single
# demonstration run), this script assumes the dual-path topology
# (testbed/topology/setup_topology.sh) is ALREADY up, and does only:
#   1. Apply "down"-direction shaping to path A and path B (burst=3200,
#      calibrated -- see testbed/calibration/).
#   2. Generate a fresh webroot test file of the requested size.
#   3. Start a stock `picoquicdemo` server in ns_server, with
#      PVSEED_SPEC_RESET set as requested, qlog enabled.
#   4. Run `harness/migrate_client` in ns_client: starts on path A
#      (10.0.1.1, natural fallback route), downloads the file, and
#      PVSEED_MIGRATE_AFTER_US into the transfer, migrates to
#      MIGRATE_TARGET_IP (path B) -- optionally ALSO changing the UDP port,
#      if MIGRATE_PORT_OVERRIDE is set (Task 1) -- with PVSEED_SPEC_RESET
#      set identically to the server.
#   5. Captures qlog from both endpoints into OUT_DIR/{qlog_client,qlog_server}.
#
# This lets a batch driver (task*_*.sh) stand up the topology ONCE, loop
# over many trials (different rates/arms/reps) by re-invoking this script
# with different environment variables, and tear down ONCE at the end --
# required by the environment's constraint that namespace-touching work
# happen inside a single self-contained WSL invocation.
#
# Required environment variables:
#   OUT_DIR              trial output directory (created fresh; must not
#                         already contain a running server from another trial)
#   RATE_A_MBIT, DELAY_A_MS      path A "down" shaping
#   RATE_B_MBIT, DELAY_B_MS      path B "down" shaping
#   FILE_SIZE_MB          test file size in MiB
#   MIGRATE_AFTER_US      microseconds into the transfer before migrating
#   SPEC_RESET            "0" or "1" -> PVSEED_SPEC_RESET for BOTH endpoints
#
# Optional environment variables:
#   LOSS_PCT              default 0
#   BURST_BYTES           default 3200 (calibrated)
#   LIMIT_PKTS            default 1000
#   MIGRATE_TARGET_IP     default 10.0.3.1 (path B)
#   MIGRATE_PORT_OVERRIDE if non-empty, PVSEED_MIGRATE_PORT=<value> (Task 1:
#                         migration changes IP AND port). If empty/unset,
#                         PVSEED_MIGRATE_PORT is left unset (port unchanged).
#   CC_ALGO               default newreno
#   CLIENT_TIMEOUT_S      default 120
#   SNI                   default pvseed.test
#   ALPN                  default hq-interop
#   TRIAL_LABEL           default "trial" (only used in log prefixes)
#
# Exit code: the migrate_client exit code (0 = clean connection close).
# Does not set up or tear down topology, and does not touch any PV-Seed
# congestion-control/RTT code -- purely a test driver.

set -uo pipefail

TB=/home/sivaa/pvseed/testbed
PQ_BUILD=/home/sivaa/pvseed/picoquic/build
CERT=/home/sivaa/pvseed/picoquic/certs/cert.pem
KEY=/home/sivaa/pvseed/picoquic/certs/key.pem
MIGRATE_CLIENT=/home/sivaa/pvseed/harness/migrate_client

TRIAL_LABEL="${TRIAL_LABEL:-trial}"
log()  { printf '[run_trial:%s] %s\n' "$TRIAL_LABEL" "$*" >&2; }
die()  { printf '[run_trial:%s][FATAL] %s\n' "$TRIAL_LABEL" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Required parameters
# ---------------------------------------------------------------------------
: "${OUT_DIR:?OUT_DIR is required}"
: "${RATE_A_MBIT:?RATE_A_MBIT is required}"
: "${DELAY_A_MS:?DELAY_A_MS is required}"
: "${RATE_B_MBIT:?RATE_B_MBIT is required}"
: "${DELAY_B_MS:?DELAY_B_MS is required}"
: "${FILE_SIZE_MB:?FILE_SIZE_MB is required}"
: "${MIGRATE_AFTER_US:?MIGRATE_AFTER_US is required}"
: "${SPEC_RESET:?SPEC_RESET is required (0 or 1)}"

LOSS_PCT="${LOSS_PCT:-0}"
BURST_BYTES="${BURST_BYTES:-3200}"
LIMIT_PKTS="${LIMIT_PKTS:-1000}"
MIGRATE_TARGET_IP="${MIGRATE_TARGET_IP:-10.0.3.1}"
MIGRATE_PORT_OVERRIDE="${MIGRATE_PORT_OVERRIDE:-}"
CC_ALGO="${CC_ALGO:-newreno}"
CLIENT_TIMEOUT_S="${CLIENT_TIMEOUT_S:-120}"
SNI="${SNI:-pvseed.test}"
ALPN="${ALPN:-hq-interop}"
SERVICE_IP=10.0.9.1
SERVER_PORT=4433

[ -x "$PQ_BUILD/picoquicdemo" ] || die "picoquicdemo not found/executable at $PQ_BUILD/picoquicdemo"
[ -x "$MIGRATE_CLIENT" ] || die "migrate_client not found/executable at $MIGRATE_CLIENT"
ip netns list | awk '{print $1}' | grep -qx ns_client || die "ns_client does not exist -- run setup_topology.sh first"
ip netns list | awk '{print $1}' | grep -qx ns_server || die "ns_server does not exist -- run setup_topology.sh first"

WEBROOT="$OUT_DIR/webroot"
DOWNLOADS="$OUT_DIR/downloads"
QLOG_SERVER="$OUT_DIR/qlog_server"
QLOG_CLIENT="$OUT_DIR/qlog_client"

rm -rf "$OUT_DIR"
mkdir -p "$WEBROOT" "$DOWNLOADS" "$QLOG_SERVER" "$QLOG_CLIENT" || die "could not create $OUT_DIR"

# ---------------------------------------------------------------------------
# Shaping (re-appliable; safe to call repeatedly across trials)
# ---------------------------------------------------------------------------
log "shaping path A: down ${RATE_A_MBIT}mbit / ${DELAY_A_MS}ms / ${LOSS_PCT}% loss, burst=${BURST_BYTES}"
bash "$TB/shaping/apply_shaping.sh" a down "$RATE_A_MBIT" "$DELAY_A_MS" "$LOSS_PCT" "$BURST_BYTES" "$LIMIT_PKTS" \
    >"$OUT_DIR/shaping_a.log" 2>&1
[ $? -eq 0 ] || die "apply_shaping.sh (path A) failed; see $OUT_DIR/shaping_a.log"

log "shaping path B: down ${RATE_B_MBIT}mbit / ${DELAY_B_MS}ms / ${LOSS_PCT}% loss, burst=${BURST_BYTES}"
bash "$TB/shaping/apply_shaping.sh" b down "$RATE_B_MBIT" "$DELAY_B_MS" "$LOSS_PCT" "$BURST_BYTES" "$LIMIT_PKTS" \
    >"$OUT_DIR/shaping_b.log" 2>&1
[ $? -eq 0 ] || die "apply_shaping.sh (path B) failed; see $OUT_DIR/shaping_b.log"

# ---------------------------------------------------------------------------
# Test file
# ---------------------------------------------------------------------------
log "generating ${FILE_SIZE_MB}MB test file"
dd if=/dev/zero of="$WEBROOT/bigfile.bin" bs=1M count="$FILE_SIZE_MB" status=none
[ -f "$WEBROOT/bigfile.bin" ] || die "failed to create test file"

# ---------------------------------------------------------------------------
# Server
# ---------------------------------------------------------------------------
log "starting picoquicdemo server (PVSEED_SPEC_RESET=$SPEC_RESET) on ${SERVICE_IP}:${SERVER_PORT}"
SERVER_PID=""
cleanup() {
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
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
}
trap cleanup RETURN EXIT

ip netns exec ns_server env PVSEED_SPEC_RESET="$SPEC_RESET" "$PQ_BUILD/picoquicdemo" \
    -p "$SERVER_PORT" -c "$CERT" -k "$KEY" -w "$WEBROOT" \
    -q "$QLOG_SERVER" -l "$OUT_DIR/server.log" -1 \
    > "$OUT_DIR/server_stdout.log" 2>&1 &
SERVER_PID=$!
sleep 1
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    cat "$OUT_DIR/server_stdout.log" >&2
    die "server process died immediately after start; see $OUT_DIR/server_stdout.log"
fi
log "server pid=$SERVER_PID"

# ---------------------------------------------------------------------------
# Client
# ---------------------------------------------------------------------------
CLIENT_ENV=(env
    PVSEED_MIGRATE_IP="$MIGRATE_TARGET_IP"
    PVSEED_MIGRATE_AFTER_US="$MIGRATE_AFTER_US"
    PVSEED_SPEC_RESET="$SPEC_RESET")
if [ -n "$MIGRATE_PORT_OVERRIDE" ]; then
    CLIENT_ENV+=(PVSEED_MIGRATE_PORT="$MIGRATE_PORT_OVERRIDE")
fi

log "starting migrate_client: cc=${CC_ALGO}, migrate -> ${MIGRATE_TARGET_IP} port_override='${MIGRATE_PORT_OVERRIDE}' after ${MIGRATE_AFTER_US}us, spec_reset=${SPEC_RESET}"
ip netns exec ns_client "${CLIENT_ENV[@]}" \
    timeout "$CLIENT_TIMEOUT_S" "$MIGRATE_CLIENT" \
    -G "$CC_ALGO" -f 3 -q "$QLOG_CLIENT" -o "$DOWNLOADS" \
    -l "$OUT_DIR/client.log" -n "$SNI" -a "$ALPN" \
    "$SERVICE_IP" "$SERVER_PORT" "bigfile.bin" \
    > "$OUT_DIR/client_stdout.log" 2>&1
CLIENT_RC=$?
log "client exited with code $CLIENT_RC"

# ---------------------------------------------------------------------------
# Quick pass/fail summary
# ---------------------------------------------------------------------------
DOWNLOADED_SIZE=$(stat -c%s "$DOWNLOADS/bigfile.bin" 2>/dev/null || echo 0)
EXPECTED_SIZE=$((FILE_SIZE_MB * 1024 * 1024))
log "downloaded file size: ${DOWNLOADED_SIZE} bytes (expected ${EXPECTED_SIZE})"
if [ "$DOWNLOADED_SIZE" -eq "$EXPECTED_SIZE" ]; then
    log "TRANSFER OK"
else
    log "TRANSFER INCOMPLETE OR MISSING -- check $OUT_DIR/client_stdout.log"
fi
if grep -q "\[pvseed\] Requesting migration:" "$OUT_DIR/client_stdout.log"; then
    log "MIGRATION TRIGGER FIRED"
else
    log "MIGRATION TRIGGER DID NOT FIRE -- check $OUT_DIR/client_stdout.log"
fi

exit "$CLIENT_RC"
