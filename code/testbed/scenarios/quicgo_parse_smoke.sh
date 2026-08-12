#!/bin/bash
set -uo pipefail
OUT=/home/sivaa/pvseed/testbed/scenarios/quicgo_parse_smoke_out.txt
RESULTS=/home/sivaa/pvseed/results/raw/quicgo/_smoke
{
  set -x
  CLIENT_SQLOG=$(find "$RESULTS/qlog_client" -name '*.sqlog' | head -1)
  SERVER_SQLOG=$(find "$RESULTS/qlog_server" -name '*.sqlog' | head -1)
  echo "client sqlog: $CLIENT_SQLOG"
  echo "server sqlog: $SERVER_SQLOG"
  python3 /home/sivaa/pvseed/analysis/parse_qlog_quicgo.py --qlog "$SERVER_SQLOG" --label arm=smoke_server --summary --csv "$RESULTS/server_metrics.csv"
  python3 /home/sivaa/pvseed/analysis/parse_qlog_quicgo.py --qlog "$CLIENT_SQLOG" --label arm=smoke_client --summary --csv "$RESULTS/client_metrics.csv"
  echo "=== server csv head ==="
  head -5 "$RESULTS/server_metrics.csv"
  wc -l "$RESULTS/server_metrics.csv"
} > "$OUT" 2>&1
echo "PARSE_SMOKE_DONE"
