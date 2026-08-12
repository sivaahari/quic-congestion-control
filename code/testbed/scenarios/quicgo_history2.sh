#!/bin/bash
set -uo pipefail
OUT=/home/sivaa/pvseed/testbed/scenarios/quicgo_history2_out.txt
cd /home/sivaa/pvseed/quic-go
{
  echo "=== tags containing 24acc54e (add support for connection migration) ==="
  git tag --contains 24acc54ef10777e086574760c54ec27fefb32a4e | sort -V | head -5
  echo "=== tags containing 9765f54d (RTTStats reset for migration) ==="
  git tag --contains 9765f54d | sort -V | head -5
  echo "=== commit message for 24acc54e in full ==="
  git show -s --format='%H%n%ad%n%s%n%n%b' 24acc54ef10777e086574760c54ec27fefb32a4e
  echo "=== commit message for 9765f54d in full ==="
  git show -s --format='%H%n%ad%n%s%n%n%b' 9765f54d
  echo "=== grep example/ for AddPath / Path usage ==="
  grep -rn "AddPath\|\.Probe(\|\.Switch(" example/ 2>&1 || echo "no matches in example/"
  echo "=== grep docs/interop for migration ==="
  grep -rln "migrat" --include=*.md . 2>&1 || echo "no md files mention migration"
  echo "=== integrationtests dir listing (may have migration test) ==="
  find integrationtests -iname "*migrat*" -o -iname "*path*" 2>&1
} > "$OUT" 2>&1
echo "HISTORY2_DONE"
