#!/bin/bash
set -uo pipefail
export PATH=/usr/local/go/bin:$PATH
export HOME=/home/sivaa
OUT=/home/sivaa/pvseed/testbed/scenarios/quicgo_build2_out.txt
cd /home/sivaa/pvseed/harness/quicgo
{
  echo "=== go build server (buildvcs=false) ==="
  go build -buildvcs=false -o bin/qgserver ./server
  echo "build_server_rc=$?"
  echo "=== go build client (buildvcs=false) ==="
  go build -buildvcs=false -o bin/qgclient ./client
  echo "build_client_rc=$?"
  echo "=== binaries ==="
  ls -la bin/
  echo "=== quick -h checks ==="
  ./bin/qgserver -h 2>&1 || true
  echo "---"
  ./bin/qgclient -h 2>&1 || true
} > "$OUT" 2>&1
echo "BUILD2_DONE"
