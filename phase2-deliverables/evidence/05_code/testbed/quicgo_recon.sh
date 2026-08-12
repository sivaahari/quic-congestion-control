#!/bin/bash
# Recon script - Phase 2 quic-go survey. Read-only, does not touch namespaces.
set -x

echo "=== whoami / uname ==="
whoami
uname -a

echo "=== go ==="
which go 2>&1
go version 2>&1

echo "=== git ==="
which git 2>&1
git --version 2>&1

echo "=== pvseed top-level ==="
find /home/sivaa/pvseed -maxdepth 2 2>&1

echo "=== pvseed testbed ==="
find /home/sivaa/pvseed/testbed -maxdepth 3 2>&1

echo "=== pvseed analysis ==="
find /home/sivaa/pvseed/analysis -maxdepth 2 2>&1

echo "=== pvseed results ==="
find /home/sivaa/pvseed/results -maxdepth 3 2>&1

echo "=== existing quic-go / picoquic clones anywhere under /home ==="
find /home -maxdepth 5 -iname "*quic-go*" 2>&1
find /home -maxdepth 5 -iname "*picoquic*" 2>&1

echo "=== disk space ==="
df -h /home 2>&1

echo "=== python3 for parse_qlog.py ==="
which python3 2>&1
python3 --version 2>&1

echo "RECON-DONE"
