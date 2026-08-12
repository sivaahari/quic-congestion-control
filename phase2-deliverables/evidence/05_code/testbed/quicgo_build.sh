#!/bin/bash
set -uo pipefail
export PATH=/usr/local/go/bin:$PATH
export HOME=/home/sivaa
OUT=/home/sivaa/pvseed/testbed/scenarios/quicgo_build_out.txt
cd /home/sivaa/pvseed/harness/quicgo
{
  echo "=== go env (relevant) ==="
  go env GOPATH GOCACHE GOMODCACHE GOTOOLCHAIN GOPROXY
  echo "=== go mod tidy ==="
  go mod tidy
  echo "tidy_rc=$?"
  echo "=== go vet ./... ==="
  go vet ./...
  echo "vet_rc=$?"
  echo "=== go build server ==="
  go build -o bin/qgserver ./server
  echo "build_server_rc=$?"
  echo "=== go build client ==="
  go build -o bin/qgclient ./client
  echo "build_client_rc=$?"
  echo "=== binaries ==="
  ls -la bin/
  file bin/qgserver bin/qgclient 2>&1 || true
  echo "=== quick -h checks ==="
  ./bin/qgserver -h 2>&1 || true
  echo "---"
  ./bin/qgclient -h 2>&1 || true
} > "$OUT" 2>&1
echo "BUILD_SCRIPT_DONE"
