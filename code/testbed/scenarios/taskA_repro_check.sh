#!/usr/bin/env bash
# taskA_repro_check.sh -- reproducibility check for the port-unset (same-port,
# different-IP) migration stall observed in taskA_port_check.sh. Runs the
# port-unset case 3x and the port-override case 1x for contrast, all in one
# self-contained topology up/down cycle.
set -uo pipefail

TB=/home/sivaa/pvseed/testbed
OUT_BASE=/home/sivaa/pvseed/results/raw/_taskA_repro
RUNLOG=/home/sivaa/pvseed/results/raw/_taskA_repro_run.log

mkdir -p "$(dirname "$RUNLOG")"
exec > >(tee "$RUNLOG") 2>&1

log() { printf '[repro] %s\n' "$*" >&2; }

bash "$TB/topology/teardown_topology.sh"
bash "$TB/topology/setup_topology.sh"

rm -rf "$OUT_BASE"
mkdir -p "$OUT_BASE"

common_env() {
    export OUT_DIR="$1"
    export RATE_A_MBIT=20
    export DELAY_A_MS=20
    export RATE_B_MBIT=20
    export DELAY_B_MS=20
    export FILE_SIZE_MB=5
    export MIGRATE_AFTER_US=1500000
    export SPEC_RESET=0
    export TRIAL_LABEL="$2"
}

for i in 1 2 3; do
    log "=== unset rep $i ==="
    common_env "$OUT_BASE/unset_rep$i" "repro-unset-$i"
    unset MIGRATE_PORT_OVERRIDE
    bash "$TB/scenarios/run_migration_trial.sh"
    log "unset rep $i exit=$?"
done

log "=== override rep1 (contrast) ==="
common_env "$OUT_BASE/override_rep1" "repro-override-1"
export MIGRATE_PORT_OVERRIDE=55001
bash "$TB/scenarios/run_migration_trial.sh"
log "override rep1 exit=$?"

bash "$TB/topology/teardown_topology.sh"
log "DONE"
