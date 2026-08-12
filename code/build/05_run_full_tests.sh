#!/usr/bin/env bash
# 05_run_full_tests.sh -- run picoquic's full default test suite (mirrors
# upstream .github/workflows/ci-tests.yml invocation).
set -uo pipefail

cd /home/sivaa/pvseed/picoquic/build || { echo "FATAL: build dir missing"; exit 1; }

ulimit -c unlimited -S

LOG=/home/sivaa/pvseed/_build/full_test_output.log

echo "=== START $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" > "$LOG"
START_EPOCH=$(date +%s)

./picoquic_ct -S .. -n -r >> "$LOG" 2>&1
RC=$?

END_EPOCH=$(date +%s)
{
  echo "=== END $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "=== EXIT_CODE=$RC ELAPSED_SEC=$((END_EPOCH-START_EPOCH)) ==="
} >> "$LOG"

echo "picoquic_ct full run finished: exit=$RC elapsed=$((END_EPOCH-START_EPOCH))s (see $LOG)"
