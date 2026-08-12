#!/usr/bin/env bash
# 22_preserve_v1_and_run_stepdown_v2.sh
# 1) Preserve the v1 (defect-contaminated) raw baseline results by renaming
#    the directory (non-destructive) -- task instructions require keeping
#    v1 "for the record" and not overwriting it.
# 2) Run the step_down scenario batch (both arms, 5 reps) against the
#    rebuilt (fixed) binaries, producing fresh v2 raw data under a clean
#    results/raw/baseline/step_down tree.
set -uo pipefail

RAW=/home/sivaa/pvseed/results/raw
LOG=/home/sivaa/pvseed/_build/22_preserve_and_stepdown_v2.log
exec > >(tee "$LOG") 2>&1

echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) preserving v1 raw baseline ==="
if [ -d "$RAW/baseline" ] && [ ! -d "$RAW/baseline_v1_contaminated" ]; then
    mv "$RAW/baseline" "$RAW/baseline_v1_contaminated"
    echo "moved $RAW/baseline -> $RAW/baseline_v1_contaminated"
elif [ -d "$RAW/baseline_v1_contaminated" ]; then
    echo "baseline_v1_contaminated already exists -- not moving again. Contents:"
    ls "$RAW/baseline_v1_contaminated"
else
    echo "WARNING: $RAW/baseline did not exist to preserve"
fi

echo "=== recompiling harness/migrate_client against the just-rebuilt libpicoquic-core.a ==="
echo "    (migrate_client.c was also edited in Task 3 -- main() now returns ret)"
bash /home/sivaa/pvseed/_build/09_compile_migrate_client.sh
[ -x /home/sivaa/pvseed/harness/migrate_client ] || { echo "FATAL: migrate_client build failed"; exit 1; }

echo "=== verifying binaries are the freshly-rebuilt (fixed) ones ==="
ls -la /home/sivaa/pvseed/picoquic/build/picoquicdemo /home/sivaa/pvseed/harness/migrate_client
md5sum /home/sivaa/pvseed/picoquic/build/picoquicdemo /home/sivaa/pvseed/harness/migrate_client

echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) running step_down suite (5 reps, both arms) ==="
bash /home/sivaa/pvseed/testbed/scenarios/run_baseline_suite.sh step_down 5
RC=$?
echo "=== step_down suite exit code: $RC ==="
echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) DONE ==="
