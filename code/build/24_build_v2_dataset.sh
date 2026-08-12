#!/usr/bin/env bash
# 24_build_v2_dataset.sh -- run build_baseline_dataset.py against the fresh
# v2 raw data (results/raw/baseline, repopulated by scripts 22/23 after v1
# was moved aside to baseline_v1_contaminated), writing to the v2-suffixed
# processed CSVs so the v1 files are never touched.
set -uo pipefail

LOG=/home/sivaa/pvseed/_build/24_build_v2_dataset.log
exec > >(tee "$LOG") 2>&1

cd /home/sivaa/pvseed/analysis || exit 1

echo "=== raw root sanity (should be ONLY v2 data, no v1) ==="
find /home/sivaa/pvseed/results/raw/baseline -maxdepth 2 -type d | sort

echo "=== running build_baseline_dataset.py ==="
python3 build_baseline_dataset.py \
    --raw-root /home/sivaa/pvseed/results/raw/baseline \
    --out-migration-csv /home/sivaa/pvseed/results/processed/baseline_migration_v2.csv \
    --out-summary-csv /home/sivaa/pvseed/results/processed/baseline_summary_v2.csv
RC=$?
echo "=== build_baseline_dataset.py exit code: $RC ==="

echo "=== v2 summary CSV (full) ==="
cat /home/sivaa/pvseed/results/processed/baseline_summary_v2.csv

echo "=== confirm v1 files untouched (mtimes should predate this run) ==="
ls -la /home/sivaa/pvseed/results/processed/baseline_migration.csv /home/sivaa/pvseed/results/processed/baseline_summary.csv
