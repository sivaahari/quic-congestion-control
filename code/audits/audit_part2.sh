#!/usr/bin/env bash
set -uo pipefail
P=/home/sivaa/pvseed
PQ=$P/picoquic/picoquic

echo "=============== 1. Test suite result with flag OFF ==============="
grep -cE "^ *Success" "$P/results/raw/_task2_full_suite_flag_off.log" 2>/dev/null
echo "--- any failures? ---"
grep -inE "fail|error" "$P/results/raw/_task2_full_suite_flag_off.log" 2>/dev/null \
    | grep -viE "no error|error_|_error|error\.c|frame_format_error|internal_error" | head -10 \
    || echo "  no failure lines matched"
echo "--- final summary lines ---"
grep -iE "test.*(passed|failed)|[0-9]+ tests" "$P/results/raw/_task2_full_suite_flag_off.log" 2>/dev/null | tail -5

echo
echo "=============== 2. flag OFF == stock behaviour? ==============="
if diff -q "$P/results/raw/_baseline_results_only.txt" "$P/results/raw/_afteredit_results_only.txt" >/dev/null 2>&1; then
    echo "  IDENTICAL -- flag OFF leaves behaviour unchanged"
    head -12 "$P/results/raw/_baseline_results_only.txt"
else
    echo "  DIFFERENT:"
    diff "$P/results/raw/_baseline_results_only.txt" "$P/results/raw/_afteredit_results_only.txt" | head -20
fi

echo
echo "=============== 3. RTT reset values: what does create_path use? ==============="
grep -n -A14 "picoquic_path_t\* picoquic_create_path" "$PQ/quicctx.c" 2>/dev/null | grep -iE "rtt|cwin" | head -12
echo "--- initial RTT / variant macros ---"
grep -rn "define PICOQUIC_INITIAL_RTT\|define PICOQUIC_INITIAL_RETRANSMIT_TIMER\|define PICOQUIC_MIN_RETRANSMIT" "$PQ/picoquic_internal.h" 2>/dev/null

echo
echo "=============== 4. interrupted verification artifacts ==============="
find "$P/results/raw/_task2_verify" -type f 2>/dev/null | head -20
echo "--- setup log tail ---"
tail -15 "$P/results/raw/_task2_verify_setup.log" 2>/dev/null

echo
echo "=============== 5. does run_migration_trial.sh look complete? ==============="
head -45 "$P/testbed/scenarios/run_migration_trial.sh" 2>/dev/null
echo "  ... [$(wc -l < "$P/testbed/scenarios/run_migration_trial.sh" 2>/dev/null) lines total]"
echo
echo "DONE"
