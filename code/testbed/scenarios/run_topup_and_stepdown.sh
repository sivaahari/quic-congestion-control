#!/usr/bin/env bash
# run_topup_and_stepdown.sh
#
# One self-contained invocation that:
#   1. Tops up step_up/specreset/rep3, which failed all 3 attempts in the
#      first step_up batch (consistent same-port-migration idle-timeout
#      stall -- the same intermittent flake characterized in Task A, not a
#      new failure mode; see analysis notes). Retries up to 5x into a FRESH
#      slot (rep3b) rather than overwriting the failed rep3 attempts, so the
#      failure evidence is preserved.
#   2. Runs the full step_down suite (2 arms x 5 reps, up to 3 attempts each,
#      same as run_baseline_suite.sh).
# in ONE topology up/down cycle.
set -uo pipefail

TB=/home/sivaa/pvseed/testbed
OUT_ROOT=/home/sivaa/pvseed/results/raw/baseline
RUNLOG=/home/sivaa/pvseed/results/raw/_topup_and_stepdown_run.log

mkdir -p "$(dirname "$RUNLOG")"
exec > >(tee "$RUNLOG") 2>&1

log()  { printf '[topup+stepdown] %s\n' "$*" >&2; }

log "=== tearing down any stale topology, then setting up fresh ==="
bash "$TB/topology/teardown_topology.sh"
bash "$TB/topology/setup_topology.sh"

# ---------------------------------------------------------------------------
# Part 1: top up step_up/specreset -- need a 5th successful rep. Use a new
# slot name (rep3b) so the original failed rep3/attempt{1,2,3} evidence is
# preserved untouched for the record.
# ---------------------------------------------------------------------------
RATE_A_MBIT=20;  DELAY_A_MS=60
RATE_B_MBIT=100; DELAY_B_MS=20
FILE_SIZE_MB=38
MIGRATE_AFTER_US=5000000
LOSS_PCT=0
BURST_BYTES=3200
LIMIT_PKTS=1000
CLIENT_TIMEOUT_S=60
MAX_TOPUP_ATTEMPTS=5

cell_dir="$OUT_ROOT/step_up/specreset/rep3b"
rm -rf "$cell_dir"
mkdir -p "$cell_dir"

transfer_ok() {
    local out_dir="$1" expected actual
    expected=$(( FILE_SIZE_MB * 1024 * 1024 ))
    actual=$(stat -c%s "$out_dir/downloads/bigfile.bin" 2>/dev/null || echo 0)
    [ "$actual" -eq "$expected" ]
}

topup_success=0
attempt=1
while [ "$attempt" -le "$MAX_TOPUP_ATTEMPTS" ]; do
    attempt_dir="$cell_dir/attempt${attempt}"
    label="stepup-specreset-r3b-a${attempt}"
    log "--- topup specreset rep3b attempt $attempt/$MAX_TOPUP_ATTEMPTS ---"
    OUT_DIR="$attempt_dir" \
    RATE_A_MBIT="$RATE_A_MBIT" DELAY_A_MS="$DELAY_A_MS" \
    RATE_B_MBIT="$RATE_B_MBIT" DELAY_B_MS="$DELAY_B_MS" \
    FILE_SIZE_MB="$FILE_SIZE_MB" \
    MIGRATE_AFTER_US="$MIGRATE_AFTER_US" \
    SPEC_RESET=1 \
    LOSS_PCT="$LOSS_PCT" BURST_BYTES="$BURST_BYTES" LIMIT_PKTS="$LIMIT_PKTS" \
    CLIENT_TIMEOUT_S="$CLIENT_TIMEOUT_S" \
    TRIAL_LABEL="$label" \
    bash "$TB/scenarios/run_migration_trial.sh"
    rc=$?
    if transfer_ok "$attempt_dir"; then
        log "topup rep3b attempt $attempt: TRANSFER OK (client_rc=$rc)"
        topup_success=1
        break
    else
        log "topup rep3b attempt $attempt: TRANSFER INCOMPLETE (client_rc=$rc)"
        attempt=$((attempt + 1))
    fi
done
if [ "$topup_success" -eq 1 ]; then
    ln -sfn "attempt${attempt}" "$cell_dir/final"
    log "TOPUP SUCCEEDED after $attempt attempt(s) -- results/raw/baseline/step_up/specreset/rep3b/final"
else
    log "TOPUP FAILED after $MAX_TOPUP_ATTEMPTS attempts -- step_up/specreset will have only 4 valid reps"
fi

# ---------------------------------------------------------------------------
# Part 2: full step_down suite (2 arms x 5 reps, <=3 attempts each) --
# same logic as run_baseline_suite.sh, inlined so this stays one topology
# up/down cycle.
# ---------------------------------------------------------------------------
RATE_A_MBIT=100; DELAY_A_MS=20
RATE_B_MBIT=20;  DELAY_B_MS=60
FILE_SIZE_MB=100
MAX_ATTEMPTS=3

declare -a RESULT_LINES

for arm_name in naive specreset; do
    if [ "$arm_name" = "naive" ]; then spec_reset=0; else spec_reset=1; fi
    for rep in 1 2 3 4 5; do
        cell_dir="$OUT_ROOT/step_down/$arm_name/rep${rep}"
        rm -rf "$cell_dir"
        mkdir -p "$cell_dir"
        attempt=1
        success=0
        while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
            attempt_dir="$cell_dir/attempt${attempt}"
            label="stepdown-${arm_name}-r${rep}-a${attempt}"
            log "--- step_down $arm_name rep $rep attempt $attempt/$MAX_ATTEMPTS ---"
            OUT_DIR="$attempt_dir" \
            RATE_A_MBIT="$RATE_A_MBIT" DELAY_A_MS="$DELAY_A_MS" \
            RATE_B_MBIT="$RATE_B_MBIT" DELAY_B_MS="$DELAY_B_MS" \
            FILE_SIZE_MB="$FILE_SIZE_MB" \
            MIGRATE_AFTER_US="$MIGRATE_AFTER_US" \
            SPEC_RESET="$spec_reset" \
            LOSS_PCT="$LOSS_PCT" BURST_BYTES="$BURST_BYTES" LIMIT_PKTS="$LIMIT_PKTS" \
            CLIENT_TIMEOUT_S="$CLIENT_TIMEOUT_S" \
            TRIAL_LABEL="$label" \
            bash "$TB/scenarios/run_migration_trial.sh"
            rc=$?
            if transfer_ok "$attempt_dir"; then
                log "step_down $arm_name rep $rep attempt $attempt: TRANSFER OK (client_rc=$rc)"
                success=1
                break
            else
                log "step_down $arm_name rep $rep attempt $attempt: TRANSFER INCOMPLETE (client_rc=$rc) -- $( [ "$attempt" -lt "$MAX_ATTEMPTS" ] && echo retrying || echo giving up )"
                attempt=$((attempt + 1))
            fi
        done
        last_attempt_dir="$cell_dir/attempt$((success == 1 ? attempt : MAX_ATTEMPTS))"
        ln -sfn "$(basename "$last_attempt_dir")" "$cell_dir/final"
        if [ "$success" -eq 1 ]; then
            RESULT_LINES+=("step_down $arm_name rep$rep: OK (attempts=$attempt)")
        else
            RESULT_LINES+=("step_down $arm_name rep$rep: FAILED after $MAX_ATTEMPTS attempts")
        fi
    done
done

log "=== tearing down topology ==="
bash "$TB/topology/teardown_topology.sh"

log "=== SUMMARY (topup + step_down) ==="
log "topup step_up/specreset/rep3b: $( [ "$topup_success" -eq 1 ] && echo OK || echo FAILED )"
for line in "${RESULT_LINES[@]}"; do
    log "$line"
done
n_failed=0
for line in "${RESULT_LINES[@]}"; do
    case "$line" in *FAILED*) n_failed=$((n_failed + 1)) ;; esac
done
log "step_down cells: ${#RESULT_LINES[@]}, failed: $n_failed"
log "=== DONE ==="
[ "$n_failed" -eq 0 ] && [ "$topup_success" -eq 1 ]
