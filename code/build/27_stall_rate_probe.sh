#!/usr/bin/env bash
# 27_stall_rate_probe.sh -- TASK 3 supplementary probe.
#
# The v2 baseline suite (scripts 22/23) only gives ~20 first-attempt data
# points for estimating the intermittent post-migration black-hole rate
# (~1-in-5 previously reported). This script runs a larger, DEDICATED batch
# of single trials (no retry-masking -- every attempt is a fresh, independent
# measurement) purely to tighten that rate estimate, using port-preserved
# migration (the configuration the black hole was reported under) across
# BOTH scenarios and BOTH arms, now that the Task 1 fix is built in.
#
# Self-contained: stands up topology once, runs N_PER_CELL trials per
# scenario/arm cell, tears down once.
#
# Usage: 27_stall_rate_probe.sh [n_per_cell]
set -uo pipefail

TB=/home/sivaa/pvseed/testbed
N_PER_CELL="${1:-8}"
OUT_ROOT=/home/sivaa/pvseed/results/raw/_task3_stall_probe
LOG=/home/sivaa/pvseed/_build/27_stall_rate_probe.log
exec > >(tee "$LOG") 2>&1

log() { printf '[stall_probe] %s\n' "$*" >&2; }

echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) sanity: binaries present ==="
ls -la /home/sivaa/pvseed/picoquic/build/picoquicdemo /home/sivaa/pvseed/harness/migrate_client || exit 1

log "=== tearing down any stale topology, then setting up fresh ==="
bash "$TB/topology/teardown_topology.sh"
bash "$TB/topology/setup_topology.sh"

rm -rf "$OUT_ROOT"
mkdir -p "$OUT_ROOT"

declare -a RESULT_LINES

run_cell() {
    local scenario="$1" spec_reset="$2"
    local rate_a delay_a rate_b delay_b file_mb
    if [ "$scenario" = "step_up" ]; then
        rate_a=20; delay_a=60; rate_b=100; delay_b=20; file_mb=38
    else
        rate_a=100; delay_a=20; rate_b=20; delay_b=60; file_mb=100
    fi
    local arm_name; [ "$spec_reset" = "0" ] && arm_name=naive || arm_name=specreset

    for i in $(seq 1 "$N_PER_CELL"); do
        local out_dir="$OUT_ROOT/${scenario}_${arm_name}/trial${i}"
        rm -rf "$out_dir"
        mkdir -p "$out_dir"
        local label="probe-${scenario}-${arm_name}-t${i}"
        log "--- $label -> $out_dir ---"
        OUT_DIR="$out_dir" \
        RATE_A_MBIT="$rate_a" DELAY_A_MS="$delay_a" \
        RATE_B_MBIT="$rate_b" DELAY_B_MS="$delay_b" \
        FILE_SIZE_MB="$file_mb" \
        MIGRATE_AFTER_US=5000000 \
        SPEC_RESET="$spec_reset" \
        BURST_BYTES=3200 LIMIT_PKTS=1000 \
        CLIENT_TIMEOUT_S=60 \
        TRIAL_LABEL="$label" \
        bash "$TB/scenarios/run_migration_trial.sh"
        rc=$?
        local expected=$(( file_mb * 1024 * 1024 ))
        local actual
        actual=$(stat -c%s "$out_dir/downloads/bigfile.bin" 2>/dev/null || echo 0)
        if [ "$actual" -eq "$expected" ]; then
            log "$label: OK (rc=$rc)"
            RESULT_LINES+=("$scenario $arm_name trial$i: OK")
        else
            log "$label: STALL/INCOMPLETE (rc=$rc, got $actual of $expected bytes)"
            RESULT_LINES+=("$scenario $arm_name trial$i: FAILED (got $actual of $expected)")
        fi
    done
}

# Focus the probe on port-preserved migration (default -- MIGRATE_PORT_OVERRIDE
# left unset by run_migration_trial.sh unless we set it, which we don't here),
# across both scenarios and both arms.
run_cell step_down 0
run_cell step_down 1
run_cell step_up 0
run_cell step_up 1

log "=== tearing down topology ==="
bash "$TB/topology/teardown_topology.sh"

log "=== SUMMARY ==="
n_failed=0
n_total=0
for line in "${RESULT_LINES[@]}"; do
    log "$line"
    n_total=$((n_total + 1))
    case "$line" in *FAILED*) n_failed=$((n_failed + 1)) ;; esac
done
log "total trials: $n_total, failed (stall/incomplete): $n_failed"
if [ "$n_total" -gt 0 ]; then
    pct=$(awk -v f="$n_failed" -v t="$n_total" 'BEGIN{printf "%.1f", 100.0*f/t}')
    log "failure rate: ${pct}%"
fi
log "=== DONE ==="
