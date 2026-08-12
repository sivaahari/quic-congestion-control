#!/usr/bin/env bash
# Audit the PVSEED_SPEC_RESET implementation before trusting it.
set -uo pipefail
P=/home/sivaa/pvseed
PQ=$P/picoquic/picoquic

echo "=============== the reset implementation (frames.c) ==============="
sed -n '4930,5010p' "$PQ/frames.c"

echo
echo "=============== the paths.c touch point ==============="
sed -n '735,765p' "$PQ/paths.c"

echo
echo "=============== header declaration ==============="
sed -n '1618,1636p' "$PQ/picoquic_internal.h"

echo
echo "=============== TEST SUITE with flag OFF: verdict lines ==============="
tail -20 "$P/results/raw/_task2_full_suite_flag_off.log" 2>/dev/null || echo "  (log missing)"

echo
echo "=============== baseline vs after-edit comparison files ==============="
echo "--- _baseline_results_only.txt ---"
cat "$P/results/raw/_baseline_results_only.txt" 2>/dev/null | head -20
echo "--- _afteredit_results_only.txt ---"
cat "$P/results/raw/_afteredit_results_only.txt" 2>/dev/null | head -20
echo "--- diff of the two ---"
diff "$P/results/raw/_baseline_results_only.txt" "$P/results/raw/_afteredit_results_only.txt" \
    && echo "  IDENTICAL (flag OFF changes nothing)" || echo "  ^^ DIFFERENCES ABOVE"

echo
echo "=============== interrupted Task 2 verification state ==============="
find "$P/results/raw/_task2_verify" -type f 2>/dev/null | head -20
echo
tail -25 "$P/results/raw/_task2_verify_setup.log" 2>/dev/null

echo
echo "DONE"
