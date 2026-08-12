#!/bin/bash
set -uo pipefail
OUT=/home/sivaa/pvseed/testbed/scenarios/quicgo_clone_out.txt
{
  if [ -d /home/sivaa/pvseed/quic-go/.git ]; then
    echo "already cloned"
  else
    git clone https://github.com/quic-go/quic-go.git /home/sivaa/pvseed/quic-go
  fi
  echo "--- commit ---"
  git -C /home/sivaa/pvseed/quic-go rev-parse HEAD
  echo "--- describe ---"
  git -C /home/sivaa/pvseed/quic-go describe --tags --always 2>&1
  echo "--- branch ---"
  git -C /home/sivaa/pvseed/quic-go branch --show-current
  echo "--- last commit log ---"
  git -C /home/sivaa/pvseed/quic-go log -1
  echo "--- go.mod ---"
  cat /home/sivaa/pvseed/quic-go/go.mod
  echo "--- top level listing ---"
  ls -la /home/sivaa/pvseed/quic-go
} > "$OUT" 2>&1
echo "CLONE_DONE"
