#!/usr/bin/env bash
# 02_clone.sh -- clone picotls and picoquic as sibling directories
set -uo pipefail

LOG=/home/sivaa/pvseed/_build/02_clone.log
exec > >(tee "$LOG") 2>&1

ROOT=/home/sivaa/pvseed

cd "$ROOT"

echo "=== cloning picotls ==="
if [ -d "$ROOT/picotls" ]; then
    echo "picotls already exists, removing for a clean clone"
    rm -rf "$ROOT/picotls"
fi
git clone https://github.com/h2o/picotls "$ROOT/picotls"
cd "$ROOT/picotls"
git submodule update --init --recursive
echo "--- picotls commit ---"
git rev-parse HEAD
git log -1 --format='%H %ci %s'

echo
echo "=== cloning picoquic ==="
cd "$ROOT"
if [ -d "$ROOT/picoquic" ]; then
    echo "picoquic already exists, removing for a clean clone"
    rm -rf "$ROOT/picoquic"
fi
git clone https://github.com/private-octopus/picoquic "$ROOT/picoquic"
cd "$ROOT/picoquic"
git submodule update --init --recursive || echo "note: picoquic has no submodules or submodule init failed (non-fatal, checking below)"
echo "--- picoquic commit ---"
git rev-parse HEAD
git log -1 --format='%H %ci %s'

echo
echo "=== directory layout (sibling check) ==="
ls -la "$ROOT" | grep -E 'picotls|picoquic'

echo "=== DONE 02_clone ==="
