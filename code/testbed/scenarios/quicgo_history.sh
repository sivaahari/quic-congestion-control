#!/bin/bash
set -uo pipefail
OUT=/home/sivaa/pvseed/testbed/scenarios/quicgo_history_out.txt
cd /home/sivaa/pvseed/quic-go
{
  echo "=== first commit introducing path_manager_outgoing.go ==="
  git log --diff-filter=A --follow --format='%H %ad %s' --date=short -- path_manager_outgoing.go | tail -5
  echo "=== first commit introducing AddPath in connection.go ==="
  git log -S "func (c *Conn) AddPath" --format='%H %ad %s' --date=short -- connection.go | tail -5
  echo "=== first commit introducing path_manager.go ==="
  git log --diff-filter=A --follow --format='%H %ad %s' --date=short -- path_manager.go | tail -5
  echo "=== total commits touching path_manager*.go ==="
  git log --oneline -- path_manager.go path_manager_outgoing.go | wc -l
  echo "=== recent commits touching path_manager*.go (last 10) ==="
  git log --oneline -n 10 -- path_manager.go path_manager_outgoing.go connection.go | head -30
  echo "=== is there a release tag containing AddPath? ==="
  git tag --contains $(git log -S "func (c *Conn) AddPath" --format='%H' -- connection.go | tail -1) 2>&1 | head -20
  echo "=== README history: any past mention of migration? ==="
  git log --oneline -S "migrat" -- README.md | head -20
  echo "=== search whole history log for 'connection migration' commit messages ==="
  git log --oneline -i --grep="migrat" | head -40
} > "$OUT" 2>&1
echo "HISTORY_DONE"
