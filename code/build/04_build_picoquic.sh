#!/usr/bin/env bash
# 04_build_picoquic.sh -- configure and build picoquic out-of-tree, against
# the sibling in-tree picotls build.
set -uo pipefail

LOG=/home/sivaa/pvseed/_build/04_build_picoquic.log
exec > >(tee "$LOG") 2>&1

cd /home/sivaa/pvseed/picoquic || { echo "FATAL: picoquic dir missing"; exit 1; }

echo "=== cmake configure (out-of-tree, build/) ==="
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug 2>&1
CMAKE_RC=$?
echo "cmake configure exit code: $CMAKE_RC"

if [ "$CMAKE_RC" -ne 0 ]; then
    echo "=== DONE 04_build_picoquic (cmake FAILED, rc=$CMAKE_RC) ==="
    exit 1
fi

echo "=== make -C build -j\$(nproc) ==="
make -C build -j"$(nproc)" 2>&1
MAKE_RC=$?
echo "make exit code: $MAKE_RC"

echo "=== resulting binaries ==="
ls -la build/picoquic_ct build/picoquicdemo build/picohttp_ct build/pqbench build/picolog_t 2>&1

echo "=== ldd picoquicdemo (sanity) ==="
ldd build/picoquicdemo 2>&1 || true

echo "=== DONE 04_build_picoquic (cmake_rc=$CMAKE_RC make_rc=$MAKE_RC) ==="
