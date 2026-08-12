#!/usr/bin/env bash
set -uo pipefail
RESULTS=/home/sivaa/pvseed/results/raw/_migrate_demo
SQ=$(find "$RESULTS/qlog_server" -name '*.qlog' | head -1)
python3 /home/sivaa/pvseed/_build/check_paths.py "$SQ"
