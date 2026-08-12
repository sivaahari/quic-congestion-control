#!/bin/bash
set -uo pipefail
OLD=/home/sivaa/pvseed/_build/full_test_output.log
NEW=/home/sivaa/pvseed/_build/20_full_test_flag_off.log

echo "=== old log line count ==="
wc -l "$OLD"
echo "=== new log line count ==="
wc -l "$NEW"

# Strip the START/END/EXIT_CODE/ELAPSED wrapper lines (timestamps/durations
# will legitimately differ run to run) and diff everything else -- this is
# the actual picoquic_ct test output, which should be fully deterministic.
grep -v -E '^=== (START|END|EXIT_CODE)' "$OLD" > /tmp_old_stripped.txt
grep -v -E '^=== (START|END|EXIT_CODE)' "$NEW" > /tmp_new_stripped.txt

echo "=== diff (stripped of timestamp/exit-code wrapper lines) ==="
diff /tmp_old_stripped.txt /tmp_new_stripped.txt
DIFF_RC=$?
echo "diff exit code: $DIFF_RC (0 = byte-identical test output)"
rm -f /tmp_old_stripped.txt /tmp_new_stripped.txt
