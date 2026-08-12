#!/usr/bin/env bash
# run_baseline_suite.sh -- TASK B batch driver.
#
# Stands up the dual-path topology ONCE, runs BOTH arms (SPEC_RESET=0 naive
# carry-over, SPEC_RESET=1 spec-compliant reset) x N_REPS reps for ONE
# scenario (step_up or step_down), and tears down ONCE. Self-contained per
# the environment's namespace-lifetime constraint.
#
# Each scenario is run as its own invocation of this script (rather than
# cramming both scenarios into one run) purely to keep any single tool
# invocation comfortably under time limits -- the environment's real
# constraint is that setup/work/teardown happen together in ONE WSL
# invocation, which this script satisfies per scenario.
#
# A trial is retried (fresh, same OUT_DIR) up to MAX_ATTEMPTS times if the
# downloaded file size doesn't match the expected size -- this guards
# against the intermittent (~20% observed in Task A testing) same-port
# migration stall where the connection idle-times-out instead of
# completing. Every attempt (including failed ones) is preserved in its own
# numbered subdirectory so nothing is silently thrown away; only the LAST
# (hopefully successful) attempt's directory is exposed at the canonical
# repN path for downstream analysis.
#
# Usage: run_baseline_suite.sh <step_up|step_down> [n_reps]

set -uo pipefail

SCENARIO="${1:?usage: run_baseline_suite.sh <step_up|step_down> [n_reps]}"
N_REPS="${2:-5}"
MAX_ATTEMPTS=3

TB=/home/sivaa/pvseed/testbed
OUT_ROOT=/home/sivaa/pvseed/results/raw/baseline
RUNLOG="/home/sivaa/pvseed/results/raw/_baseline_${SCENARIO}_run.log"

mkdir -p "$(dirname "$RUNLOG")"
exec > >(tee "$RUNLOG") 2>&1

log()  { printf '[suite:%s] %s\n' "$SCENARIO" "$*" >&2; }
die()  { printf '[suite:%s][FATAL] %s\n' "$SCENARIO" "$*" >&2; exit 1; }

case "$SCENARIO" in
    step_up)
        # Path A (start) 20Mbit/60ms -> Path B (end) 100Mbit/20ms.
        RATE_A_MBIT=20;  DELAY_A_MS=60
        RATE_B_MBIT=100; DELAY_B_MS=20
        # ~15s worth of data at the slower path's (A, 20mbit) rate.
        FILE_SIZE_MB=38
        ;;
    step_down)
        # Path A (start) 100Mbit/20ms -> Path B (end) 20Mbit/60ms.
        RATE_A_MBIT=100; DELAY_A_MS=20
        RATE_B_MBIT=20;  DELAY_B_MS=60
        # Must survive >5s on the FAST starting path (100mbit*5s=62.5MB)
        # AND still leave ~15s worth of data at the slow ending path's
        # (B, 20mbit) rate for the post-migration recovery window:
        # 62.5MB + 37.5MB = 100MB.
        FILE_SIZE_MB=100
        ;;
    *) die "unknown scenario '$SCENARIO' (expected step_up or step_down)" ;;
esac

MIGRATE_AFTER_US=5000000   # ~5s in
LOSS_PCT=0
BURST_BYTES=3200
LIMIT_PKTS=1000
CLIENT_TIMEOUT_S=60

log "=== tearing down any stale topology, then setting up fresh ==="
bash "$TB/topology/teardown_topology.sh"
bash "$TB/topology/setup_topology.sh"

mkdir -p "$OUT_ROOT/$SCENARIO"

declare -a RESULT_LINES

run_one_attempt() {
    local out_dir="$1" arm_spec_reset="$2" trial_label="$3"
    OUT_DIR="$out_dir" \
    RATE_A_MBIT="$RATE_A_MBIT" DELAY_A_MS="$DELAY_A_MS" \
    RATE_B_MBIT="$RATE_B_MBIT" DELAY_B_MS="$DELAY_B_MS" \
    FILE_SIZE_MB="$FILE_SIZE_MB" \
    MIGRATE_AFTER_US="$MIGRATE_AFTER_US" \
    SPEC_RESET="$arm_spec_reset" \
    LOSS_PCT="$LOSS_PCT" BURST_BYTES="$BURST_BYTES" LIMIT_PKTS="$LIMIT_PKTS" \
    CLIENT_TIMEOUT_S="$CLIENT_TIMEOUT_S" \
    TRIAL_LABEL="$trial_label" \
    bash "$TB/scenarios/run_migration_trial.sh"
    return $?
}

transfer_ok() {
    local out_dir="$1"
    local expected=$(( FILE_SIZE_MB * 1024 * 1024 ))
    local actual
    actual=$(stat -c%s "$out_dir/downloads/bigfile.bin" 2>/dev/null || echo 0)
    [ "$actual" -eq "$expected" ]
}

for arm_name in naive specreset; do
    if [ "$arm_name" = "naive" ]; then spec_reset=0; else spec_reset=1; fi
    for rep in $(seq 1 "$N_REPS"); do
        cell_dir="$OUT_ROOT/$SCENARIO/$arm_name/rep${rep}"
        rm -rf "$cell_dir"
        mkdir -p "$cell_dir"
        attempt=1
        success=0
        while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
            attempt_dir="$cell_dir/attempt${attempt}"
            label="${SCENARIO}-${arm_name}-r${rep}-a${attempt}"
            log "--- $arm_name rep $rep attempt $attempt/$MAX_ATTEMPTS -> $attempt_dir ---"
            run_one_attempt "$attempt_dir" "$spec_reset" "$label"
            rc=$?
            if transfer_ok "$attempt_dir"; then
                log "$arm_name rep $rep attempt $attempt: TRANSFER OK (client_rc=$rc)"
                success=1
                break
            else
                log "$arm_name rep $rep attempt $attempt: TRANSFER INCOMPLETE (client_rc=$rc) -- $( [ "$attempt" -lt "$MAX_ATTEMPTS" ] && echo retrying || echo giving up )"
                attempt=$((attempt + 1))
            fi
        done
        # Expose the last attempt (successful, or final failed one if all
        # attempts were exhausted) at the canonical repN path via symlink,
        # so downstream analysis has one predictable location per cell.
        last_attempt_dir="$cell_dir/attempt$((success == 1 ? attempt : MAX_ATTEMPTS))"
        ln -sfn "$(basename "$last_attempt_dir")" "$cell_dir/final"
        if [ "$success" -eq 1 ]; then
            RESULT_LINES+=("$SCENARIO $arm_name rep$rep: OK (attempts=$attempt)")
        else
            RESULT_LINES+=("$SCENARIO $arm_name rep$rep: FAILED after $MAX_ATTEMPTS attempts")
        fi
    done
done

log "=== tearing down topology ==="
bash "$TB/topology/teardown_topology.sh"

log "=== SUMMARY ($SCENARIO) ==="
for line in "${RESULT_LINES[@]}"; do
    log "$line"
done

n_failed=0
for line in "${RESULT_LINES[@]}"; do
    case "$line" in *FAILED*) n_failed=$((n_failed + 1)) ;; esac
done
log "total cells: ${#RESULT_LINES[@]}, failed: $n_failed"
log "=== DONE ($SCENARIO) ==="
[ "$n_failed" -eq 0 ]
