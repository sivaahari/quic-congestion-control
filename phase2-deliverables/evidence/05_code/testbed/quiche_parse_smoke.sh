#!/usr/bin/env bash
set -uo pipefail

cd /home/sivaa/pvseed || exit 1

SERVER_QLOG=$(find results/raw/quiche/smoke/qlog_server -name '*.sqlog' 2>/dev/null | head -1)
CLIENT_QLOG=$(find results/raw/quiche/smoke/qlog_client -name '*.sqlog' 2>/dev/null | head -1)

echo "server qlog: $SERVER_QLOG"
echo "client qlog: $CLIENT_QLOG"

if [ -z "$SERVER_QLOG" ] || [ -z "$CLIENT_QLOG" ]; then
    echo "FATAL: qlog files not found" >&2
    exit 1
fi

python3 analysis/parse_qlog_quiche.py --qlog "$SERVER_QLOG" --label arm=smoke_server --csv /home/sivaa/pvseed/results/raw/quiche/smoke/server.csv --summary
echo "--- head of server csv ---"
head -5 /home/sivaa/pvseed/results/raw/quiche/smoke/server.csv
echo "--- row count ---"
wc -l /home/sivaa/pvseed/results/raw/quiche/smoke/server.csv

python3 analysis/parse_qlog_quiche.py --qlog "$CLIENT_QLOG" --label arm=smoke_client --summary
