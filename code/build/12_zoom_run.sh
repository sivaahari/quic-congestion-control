#!/usr/bin/env bash
set -uo pipefail
RESULTS=/home/sivaa/pvseed/results/raw/_migrate_demo
SQ=$(find "$RESULTS/qlog_server" -name '*.qlog' | head -1)
python3 /home/sivaa/pvseed/_build/zoom_qlog.py "$SQ" 3995000 4010000 > /home/sivaa/pvseed/_build/zoom_server.txt 2>&1
wc -l /home/sivaa/pvseed/_build/zoom_server.txt
grep -c 'packet_lost' /home/sivaa/pvseed/_build/zoom_server.txt
