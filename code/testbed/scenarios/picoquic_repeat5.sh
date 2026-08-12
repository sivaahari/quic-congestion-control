#!/usr/bin/env bash
# picoquic_repeat5.sh
#
# Restores repetition parity for picoquic: five live repetitions where the
# original survey had one.
#
# TWO deliberate differences from the Phase-1 run this supersedes
# (testbed/scenarios/task2_verify_spec_reset.sh):
#
#   1. RATE 20 Mbit, not 50. The other four implementations were all measured at
#      the Phase-2 standard operating point, so picoquic's single Phase-1 run was
#      not directly comparable with them. It is now.
#   2. Each repetition is parsed and archived BEFORE the next one starts. The
#      quic-go trial script hardcoded its output directory and later repeats
#      silently overwrote earlier ones, which is how a reported n=4 turned out to
#      be n=3. Not repeating that.
#
# Stock picoquic: PVSEED_SPEC_RESET=0. Our own §9.4 patch is present in the tree
# but env-gated, and stays off -- the survey is about upstream behaviour.
#
# ONE self-contained invocation: the WSL2 VM discards network namespaces when it
# idles between invocations, so setup, all five runs and teardown happen here.

set -uo pipefail

TB=/home/sivaa/pvseed/testbed
A=/home/sivaa/pvseed/analysis
RESULTS=/home/sivaa/pvseed/results/raw/picoquic/reps
N="${N:-5}"

log() { printf '[picoquic_repeat5] %s\n' "$*" >&2; }

mkdir -p "$RESULTS"

bash "$TB/topology/teardown_topology.sh" >/dev/null 2>&1 || true
log "setting up topology"
if ! bash "$TB/topology/setup_topology.sh" >"$RESULTS/setup.log" 2>&1; then
    log "FATAL: setup_topology.sh failed"; tail -30 "$RESULTS/setup.log" >&2; exit 1
fi
trap 'log "tearing down topology"; bash "$TB/topology/teardown_topology.sh" >>"$RESULTS/setup.log" 2>&1' EXIT

# Phase-2 standard operating point, identical to quic-go / quiche / msquic / ngtcp2.
COMMON_ENV=(
    RATE_A_MBIT=20 DELAY_A_MS=20
    RATE_B_MBIT=20 DELAY_B_MS=40
    BURST_BYTES=3200
    FILE_SIZE_MB=50            # ~20 s at 20 Mbit, matching the other four
    MIGRATE_AFTER_US=5000000   # 5 s in
    MIGRATE_TARGET_IP=10.0.3.1
    CC_ALGO=newreno
    CLIENT_TIMEOUT_S=120
)

ok=0
for i in $(seq 1 "$N"); do
    OUT="$RESULTS/rep_$i"
    log "=== repetition $i/$N -> $OUT ==="
    env "${COMMON_ENV[@]}" OUT_DIR="$OUT" SPEC_RESET=0 TRIAL_LABEL="rep$i" \
        bash "$TB/scenarios/run_migration_trial.sh" >"$RESULTS/rep_$i.runlog" 2>&1
    rc=$?
    log "  trial exit code: $rc"

    # Parse and archive NOW, before the next repetition can touch anything.
    SRV=$(ls -S "$OUT/qlog_server/"*.qlog 2>/dev/null | head -1)
    if [ -n "$SRV" ]; then
        python3 "$A/parse_qlog.py" --qlog "$SRV" \
            --csv "$OUT/server_metrics.csv" --summary \
            > "$OUT/server_summary.txt" 2>&1
        log "  parsed: $(basename "$SRV") -> server_metrics.csv"
        grep -aiE "cwnd|reset|migrat|rtt" "$OUT/server_summary.txt" | head -6 >&2
        ok=$((ok + 1))
    else
        log "  WARNING: no server qlog produced for rep $i"
    fi

    # Confirm the migration was a genuine ADDRESS change, not a port rebinding --
    # RFC 9000 §9.4 exempts port-only changes, so a port-only run measures nothing.
    grep -aiE "Simulating migration to NEW ADDRESS" "$OUT/client_stdout.log" 2>/dev/null \
        | head -1 >&2 || log "  WARNING: no address-change line in client log"
done

log "=== done: $ok/$N repetitions produced a parsed server trace ==="
ls -1 "$RESULTS"/rep_*/server_metrics.csv 2>/dev/null | sed 's/^/  /' >&2
