#!/usr/bin/env bash
# task2_verify_spec_reset.sh
#
# Phase 1 / Task 2 -- VERIFY IT WORKS. Runs the SAME migration (IP-only,
# path A 50Mbit/20ms -> path B 50Mbit/40ms, 64MB, migrate 4s in -- identical
# parameters to testbed/scenarios/migrate_demo.sh, for direct comparability)
# twice: once with PVSEED_SPEC_RESET=0 (stock/"naive" picoquic behaviour)
# and once with PVSEED_SPEC_RESET=1 (the new RFC 9000 9.4 reset). Captures
# qlog from both endpoints for both runs so the congestion window at the
# migration instant can be compared directly: this is the evidence for
# "does the flag actually do what it claims".
#
# ONE self-contained invocation: sets up topology, runs both trials via
# run_migration_trial.sh, tears down.

set -uo pipefail

TB=/home/sivaa/pvseed/testbed
RESULTS=/home/sivaa/pvseed/results/raw/_task2_verify

log()  { printf '[task2_verify] %s\n' "$*" >&2; }

bash "$TB/topology/teardown_topology.sh" >/dev/null 2>&1 || true
log "setting up topology"
bash "$TB/topology/setup_topology.sh" >"/home/sivaa/pvseed/results/raw/_task2_verify_setup.log" 2>&1
SETUP_RC=$?
if [ "$SETUP_RC" -ne 0 ]; then
    log "FATAL: setup_topology.sh failed (rc=$SETUP_RC)"
    tail -40 "/home/sivaa/pvseed/results/raw/_task2_verify_setup.log" >&2
    exit 1
fi

teardown() {
    log "tearing down topology"
    bash "$TB/topology/teardown_topology.sh" >>"/home/sivaa/pvseed/results/raw/_task2_verify_setup.log" 2>&1
}
trap teardown EXIT

COMMON_ENV=(
    RATE_A_MBIT=50 DELAY_A_MS=20
    RATE_B_MBIT=50 DELAY_B_MS=40
    FILE_SIZE_MB=64
    MIGRATE_AFTER_US=4000000
    MIGRATE_TARGET_IP=10.0.3.1
    CC_ALGO=newreno
    CLIENT_TIMEOUT_S=90
)

log "=== TRIAL 1/2: PVSEED_SPEC_RESET=0 (naive / stock picoquic behaviour) ==="
env "${COMMON_ENV[@]}" OUT_DIR="$RESULTS/naive" SPEC_RESET=0 TRIAL_LABEL=naive \
    bash "$TB/scenarios/run_migration_trial.sh"
RC0=$?
log "naive trial exit code: $RC0"

log "=== TRIAL 2/2: PVSEED_SPEC_RESET=1 (RFC 9000 9.4 reset) ==="
env "${COMMON_ENV[@]}" OUT_DIR="$RESULTS/reset" SPEC_RESET=1 TRIAL_LABEL=reset \
    bash "$TB/scenarios/run_migration_trial.sh"
RC1=$?
log "reset trial exit code: $RC1"

log "done. naive_rc=$RC0 reset_rc=$RC1"
log "qlog files:"
find "$RESULTS" -name '*.qlog' >&2

if [ "$RC0" -eq 0 ] && [ "$RC1" -eq 0 ]; then
    exit 0
else
    exit 1
fi
