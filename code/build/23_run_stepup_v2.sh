#!/usr/bin/env bash
# 23_run_stepup_v2.sh -- run the step_up scenario batch (both arms, 5 reps)
# against the rebuilt (fixed) binaries. Run AFTER 22_preserve_v1_and_run_
# stepdown_v2.sh (which already preserved v1 raw data and recompiled
# migrate_client); this script just runs the second scenario.
set -uo pipefail

LOG=/home/sivaa/pvseed/_build/23_stepup_v2.log
exec > >(tee "$LOG") 2>&1

echo "=== sanity: binaries present ==="
ls -la /home/sivaa/pvseed/picoquic/build/picoquicdemo /home/sivaa/pvseed/harness/migrate_client || {
    echo "FATAL: binaries missing, run 22_preserve_v1_and_run_stepdown_v2.sh first";
    exit 1;
}

echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) running step_up suite (5 reps, both arms) ==="
bash /home/sivaa/pvseed/testbed/scenarios/run_baseline_suite.sh step_up 5
RC=$?
echo "=== step_up suite exit code: $RC ==="
echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) DONE ==="
