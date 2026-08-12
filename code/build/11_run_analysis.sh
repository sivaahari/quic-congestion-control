#!/usr/bin/env bash
set -uo pipefail

RESULTS=/home/sivaa/pvseed/results/raw/_migrate_demo

echo "--- listing qlog dirs ---"
find "$RESULTS/qlog_client" "$RESULTS/qlog_server" -type f

CQ=$(find "$RESULTS/qlog_client" -name '*.qlog' | head -1)
SQ=$(find "$RESULTS/qlog_server" -name '*.qlog' | head -1)

echo "client qlog: $CQ"
echo "server qlog: $SQ"

python3 /home/sivaa/pvseed/_build/analyze_migration_qlog.py "$SQ" SERVER > /home/sivaa/pvseed/_build/analysis_server.txt 2>&1
python3 /home/sivaa/pvseed/_build/analyze_migration_qlog.py "$CQ" CLIENT > /home/sivaa/pvseed/_build/analysis_client.txt 2>&1

echo "=== analysis_server.txt ==="
cat /home/sivaa/pvseed/_build/analysis_server.txt
