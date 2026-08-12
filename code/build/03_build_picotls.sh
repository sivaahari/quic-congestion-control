#!/usr/bin/env bash
# 03_build_picotls.sh -- build picotls IN-TREE (required by picoquic's
# FindPTLS.cmake, which looks for libpicotls-*.a directly under ../picotls,
# i.e. NOT in a build/ subdirectory).
set -uo pipefail

LOG=/home/sivaa/pvseed/_build/03_build_picotls.log
exec > >(tee "$LOG") 2>&1

cd /home/sivaa/pvseed/picotls || { echo "FATAL: picotls dir missing"; exit 1; }

echo "=== cmake configure (in-tree) ==="
cmake . 2>&1
CMAKE_RC=$?
echo "cmake configure exit code: $CMAKE_RC"

echo "=== make -j\$(nproc) ==="
make -j"$(nproc)" 2>&1
MAKE_RC=$?
echo "make exit code: $MAKE_RC"

echo "=== resulting libraries ==="
ls -la *.a 2>&1

echo "=== DONE 03_build_picotls (cmake_rc=$CMAKE_RC make_rc=$MAKE_RC) ==="
