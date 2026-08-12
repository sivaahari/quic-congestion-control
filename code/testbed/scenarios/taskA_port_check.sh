#!/usr/bin/env bash
# taskA_port_check.sh
#
# TASK A empirical check: stands up the dual-path topology ONCE, runs the
# migration trial driver twice (PVSEED_MIGRATE_PORT unset, then set to an
# explicit different port), and tears down ONCE. Self-contained per the
# environment's namespace-lifetime constraint.
set -uo pipefail

TB=/home/sivaa/pvseed/testbed
OUT_BASE=/home/sivaa/pvseed/results/raw/_taskA_portcheck
RUNLOG=/home/sivaa/pvseed/results/raw/_taskA_portcheck_run.log

mkdir -p "$(dirname "$RUNLOG")"
exec > >(tee "$RUNLOG") 2>&1

log() { printf '[taskA] %s\n' "$*" >&2; }

log "=== tearing down any stale topology, then setting up fresh ==="
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

log "=== VARIANT (i): PVSEED_MIGRATE_PORT unset ==="
common_env "$OUT_BASE/unset" "taskA-unset"
unset MIGRATE_PORT_OVERRIDE
bash "$TB/scenarios/run_migration_trial.sh"
echo "exit code variant(i): $?" >&2

log "=== VARIANT (ii): PVSEED_MIGRATE_PORT=55001 (explicit, different from any likely current port) ==="
common_env "$OUT_BASE/override" "taskA-override"
export MIGRATE_PORT_OVERRIDE=55001
bash "$TB/scenarios/run_migration_trial.sh"
echo "exit code variant(ii): $?" >&2

log "=== tearing down topology ==="
bash "$TB/topology/teardown_topology.sh"

log "=== DONE ==="
