#!/usr/bin/env bash
# 20_rebuild_and_test_flag_off.sh -- rebuild picoquic after the PV-Seed
# Task 1 fix (frames.c / picoquic_internal.h changes) and run the full
# default test suite with PVSEED_SPEC_RESET unset (control arm), exactly as
# the project's own CI does. Self-contained: build + test in one invocation.
set -uo pipefail

LOG=/home/sivaa/pvseed/_build/20_rebuild_and_test_flag_off.log
exec > >(tee "$LOG") 2>&1

cd /home/sivaa/pvseed/picoquic || { echo "FATAL: picoquic dir missing"; exit 1; }

echo "=== cmake configure (out-of-tree, build/) ==="
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
CMAKE_RC=$?
echo "cmake configure exit code: $CMAKE_RC"
if [ "$CMAKE_RC" -ne 0 ]; then
    echo "=== DONE (cmake FAILED, rc=$CMAKE_RC) ==="
    exit 1
fi

echo "=== make -C build -j\$(nproc) ==="
make -C build -j"$(nproc)"
MAKE_RC=$?
echo "make exit code: $MAKE_RC"
if [ "$MAKE_RC" -ne 0 ]; then
    echo "=== DONE (make FAILED, rc=$MAKE_RC) ==="
    exit 1
fi

echo "=== resulting binaries ==="
ls -la build/picoquic_ct build/picoquicdemo 2>&1

echo "=== unset PVSEED_SPEC_RESET (control arm, must be byte-identical to stock) ==="
unset PVSEED_SPEC_RESET
env | grep -i PVSEED || echo "(PVSEED_SPEC_RESET not set -- good)"

cd build || { echo "FATAL: build dir missing"; exit 1; }
ulimit -c unlimited -S

TESTLOG=/home/sivaa/pvseed/_build/20_full_test_flag_off.log
echo "=== START $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" > "$TESTLOG"
START_EPOCH=$(date +%s)

./picoquic_ct -S .. -n -r >> "$TESTLOG" 2>&1
RC=$?

END_EPOCH=$(date +%s)
{
  echo "=== END $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "=== EXIT_CODE=$RC ELAPSED_SEC=$((END_EPOCH-START_EPOCH)) ==="
} >> "$TESTLOG"

echo "=== tail of test log ==="
tail -n 40 "$TESTLOG"

echo "=== summary counts ==="
grep -c "^Test" "$TESTLOG" || true
grep -i "fail" "$TESTLOG" | grep -v "^0 tests failed" || true

echo "picoquic_ct full run finished: exit=$RC elapsed=$((END_EPOCH-START_EPOCH))s (see $TESTLOG)"
echo "=== SCRIPT DONE ==="
