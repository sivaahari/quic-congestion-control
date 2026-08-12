#!/usr/bin/env bash
set -uo pipefail
RESULTS=/home/sivaa/pvseed/results/raw/_migrate_demo
SQ=$(find "$RESULTS/qlog_server" -name '*.qlog' | head -1)
CQ=$(find "$RESULTS/qlog_client" -name '*.qlog' | head -1)
echo "=== SERVER: datagram_sent addr_to transitions (where the server is sending replies) ==="
python3 /home/sivaa/pvseed/_build/check_ports.py "$SQ" datagram_sent
echo ""
echo "=== SERVER: datagram_received addr_to transitions ==="
python3 /home/sivaa/pvseed/_build/check_ports.py "$SQ" datagram_received
echo ""
echo "=== CLIENT: datagram_sent addr_to transitions (where the client is sending FROM/TO) ==="
python3 /home/sivaa/pvseed/_build/check_ports.py "$CQ" datagram_sent
