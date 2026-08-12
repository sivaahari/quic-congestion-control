#!/bin/bash
set -uo pipefail
OUT=/home/sivaa/pvseed/testbed/scenarios/quicgo_parse_real_out.txt
RESULTS=/home/sivaa/pvseed/results/raw/quicgo/migrate_demo
{
  set -x
  CLIENT_SQLOG=$(find "$RESULTS/qlog_client" -name '*.sqlog' | head -1)
  SERVER_SQLOG=$(find "$RESULTS/qlog_server" -name '*.sqlog' | head -1)
  echo "client sqlog: $CLIENT_SQLOG"
  echo "server sqlog: $SERVER_SQLOG"
  python3 /home/sivaa/pvseed/analysis/parse_qlog_quicgo.py --qlog "$SERVER_SQLOG" --label arm=real_server --summary --csv "$RESULTS/server_metrics.csv"
  python3 /home/sivaa/pvseed/analysis/parse_qlog_quicgo.py --qlog "$CLIENT_SQLOG" --label arm=real_client --summary --csv "$RESULTS/client_metrics.csv"
} > "$OUT" 2>&1
echo "PARSE_REAL_DONE"
