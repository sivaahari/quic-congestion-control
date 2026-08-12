#!/bin/bash
set -uo pipefail
OUT=/home/sivaa/pvseed/testbed/scenarios/install_go_out.txt
{
  set -e
  which curl || (apt-get update && apt-get install -y curl)
  echo "--- fetching go release list ---"
  curl -fsSL 'https://go.dev/dl/?mode=json' -o /home/sivaa/pvseed/testbed/scenarios/go_releases.json
  echo "fetched, size:"
  wc -c /home/sivaa/pvseed/testbed/scenarios/go_releases.json
} > "$OUT" 2>&1
echo "STEP1_DONE rc=$?"
