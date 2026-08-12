#!/usr/bin/env bash
# Assemble a submittable evidence bundle.
#
# The full raw dataset is ~2.6 GB (138 qlog files, some 46 MB each). That is
# not submittable, and most of it is redundant. This copies the artefacts that
# actually EVIDENCE the experiments -- summary data, per-trial data, test
# output, run logs, the code, and the source diff -- plus ONE representative
# qlog pair so a reviewer can inspect the raw protocol trace format.
set -uo pipefail
P=/home/sivaa/pvseed
OUT=/mnt/d/Users/Sivaa/Desktop/SEM-5/Computer-Networks/capstone-research/phase1-deliverables/evidence

rm -rf "$OUT"
mkdir -p "$OUT"/{01_calibration,02_measurements,03_test_output,04_run_logs,05_code,06_sample_traces}

echo "=== 01 calibration (emulator validation) ==="
cp -f "$P/results/processed/calibration.csv"          "$OUT/01_calibration/" 2>/dev/null
cp -f "$P/results/processed/sustained.csv"            "$OUT/01_calibration/" 2>/dev/null
cp -f "$P/results/processed/train_length_sweep.csv"   "$OUT/01_calibration/" 2>/dev/null
cp -f "$P/results/raw/calibration_raw.csv"            "$OUT/01_calibration/" 2>/dev/null
cp -f "$P/results/raw/sustained_raw.csv"              "$OUT/01_calibration/" 2>/dev/null
cp -f "$P/results/raw/train_length_sweep_raw.csv"     "$OUT/01_calibration/" 2>/dev/null
cp -f "$P"/results/raw/_audit/aud_*.json              "$OUT/01_calibration/" 2>/dev/null
ls -1 "$OUT/01_calibration/"

echo
echo "=== 02 measurements (the findings) ==="
cp -f "$P/results/processed/baseline_migration.csv"   "$OUT/02_measurements/" 2>/dev/null
cp -f "$P/results/processed/baseline_summary.csv"     "$OUT/02_measurements/" 2>/dev/null
ls -1 "$OUT/02_measurements/"

echo
echo "=== 03 test output (proves the build is sound + control is clean) ==="
cp -f "$P/results/raw/_task2_full_suite_flag_off.log" "$OUT/03_test_output/" 2>/dev/null
cp -f "$P/results/raw/_baseline_results_only.txt"     "$OUT/03_test_output/" 2>/dev/null
cp -f "$P/results/raw/_afteredit_results_only.txt"    "$OUT/03_test_output/" 2>/dev/null
cp -f "$P/results/raw/_tls_full_output.log"           "$OUT/03_test_output/" 2>/dev/null
# a diff proving the two test outputs are byte-identical
if diff -q "$P/results/raw/_baseline_results_only.txt" \
           "$P/results/raw/_afteredit_results_only.txt" >/dev/null 2>&1; then
    echo "IDENTICAL - our change with the flag OFF does not alter picoquic's own test output." \
        > "$OUT/03_test_output/CONTROL_IS_CLEAN.txt"
    diff "$P/results/raw/_baseline_results_only.txt" \
         "$P/results/raw/_afteredit_results_only.txt" \
        >> "$OUT/03_test_output/CONTROL_IS_CLEAN.txt" 2>&1
fi
ls -1 "$OUT/03_test_output/"

echo
echo "=== 04 run logs (the experiments executing) ==="
for f in _baseline_step_down_run.log _baseline_step_up_run.log \
         _topup_and_stepdown_run.log _verify_routing_output.log \
         _task2_verify_setup.log _taskA_portcheck_run.log \
         _taskA_repro_run.log _task2_rebuild1.log; do
    cp -f "$P/results/raw/$f" "$OUT/04_run_logs/" 2>/dev/null
done
ls -1 "$OUT/04_run_logs/"

echo
echo "=== 05 code (the experiment apparatus) ==="
mkdir -p "$OUT/05_code"/{testbed,analysis,harness}
cp -rf "$P/testbed/." "$OUT/05_code/testbed/" 2>/dev/null
cp -f "$P"/analysis/*.py "$OUT/05_code/analysis/" 2>/dev/null
cp -f "$P/harness/migrate_client.c" "$OUT/05_code/harness/" 2>/dev/null
# the exact source change we made to picoquic
git -C "$P/picoquic" diff HEAD > "$OUT/05_code/picoquic_our_changes.diff" 2>/dev/null
git -C "$P/picoquic" rev-parse HEAD > "$OUT/05_code/picoquic_upstream_commit.txt" 2>/dev/null
git -C "$P/picotls"  rev-parse HEAD > "$OUT/05_code/picotls_upstream_commit.txt" 2>/dev/null
echo "  testbed: $(find "$OUT/05_code/testbed" -type f | wc -l) files"
echo "  analysis: $(ls -1 "$OUT/05_code/analysis" | wc -l) files"
echo "  diff: $(wc -l < "$OUT/05_code/picoquic_our_changes.diff" 2>/dev/null) lines"

echo
echo "=== 06 sample traces (one representative pair, gzipped) ==="
SRV=$(ls -S "$P"/results/raw/_task2_verify/reset/qlog_server/*.qlog 2>/dev/null | head -1)
CLI=$(ls -S "$P"/results/raw/_task2_verify/reset/qlog_client/*.qlog 2>/dev/null | head -1)
SRV_N=$(ls -S "$P"/results/raw/_task2_verify/naive/qlog_server/*.qlog 2>/dev/null | head -1)
for f in "$SRV" "$CLI" "$SRV_N"; do
    [ -f "$f" ] && gzip -c "$f" > "$OUT/06_sample_traces/$(basename "$f").gz"
done
cp -f "$P"/results/raw/_task2_verify/*/[cs]*_stdout.log "$OUT/06_sample_traces/" 2>/dev/null
ls -lh "$OUT/06_sample_traces/" | tail -8

echo
echo "=============================================="
echo "BUNDLE SIZE: $(du -sh "$OUT" | cut -f1)"
echo "FILE COUNT : $(find "$OUT" -type f | wc -l)"
echo "=============================================="
