#!/bin/bash
set -uo pipefail
OUT=/home/sivaa/pvseed/testbed/scenarios/install_go2_out.txt
WORKDIR=/home/sivaa/pvseed/testbed/scenarios
{
  set -e
  python3 - "$WORKDIR/go_releases.json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    releases = json.load(f)
rel = releases[0]
print("latest_version:", rel["version"], "stable:", rel["stable"])
for f in rel["files"]:
    if f["os"] == "linux" and f["arch"] == "amd64" and f["kind"] == "archive":
        print("FILENAME=" + f["filename"])
        print("SHA256=" + f["sha256"])
        break
PYEOF
} > "$OUT" 2>&1
cat "$OUT"
