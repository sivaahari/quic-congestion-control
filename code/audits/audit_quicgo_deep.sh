#!/usr/bin/env bash
# THOROUGH audit of the quic-go finding, closing the gaps left by the first pass.
#
# A. Could the cwnd collapse be LOSS rather than a RESET? (the headline risk)
# B. Was the migration a genuine IP change, not port-only?
# C. Did traffic actually traverse two DIFFERENT paths?
# D. Which MigratedPath call site fired - client or server?
# E. Is our own harness code sound?
set -uo pipefail
Q=/home/sivaa/pvseed/quic-go
R=/home/sivaa/pvseed/results/raw/quicgo/migrate_demo

echo "=============================================================="
echo "A. RESET vs LOSS -- can they be told apart?"
echo "=============================================================="
echo "--- minimum congestion window (the loss floor) ---"
grep -rn "minCongestionWindow\|minCongestionWindowPackets" \
    "$Q/internal/congestion/cubic_sender.go" "$Q/internal/protocol/params.go" 2>/dev/null | head -8
echo
echo "--- where is cwnd set on loss? (multiplicative decrease) ---"
grep -n -B3 -A12 "func (c \*cubicSender) OnCongestionEvent\|func (c \*cubicSender) onPacketLost" \
    "$Q/internal/congestion/cubic_sender.go" 2>/dev/null | head -40
echo
echo "--- Reno beta / renoBeta ---"
grep -rn "renoBeta\|Beta()" "$Q/internal/congestion/"*.go 2>/dev/null | grep -v _test | head -8

echo
echo "=============================================================="
echo "B. Was it a genuine IP CHANGE (not port-only)?"
echo "=============================================================="
grep -iE "MIGRATE|LocalAddr|cutover|10\.0\.[13]\.1" "$R/client_stdout.log" 2>/dev/null | head -12

echo
echo "=============================================================="
echo "C. Did traffic really use TWO paths? (shaping applied per path)"
echo "=============================================================="
echo "--- path A shaping ---"; head -6 "$R/shaping_a.log" 2>/dev/null
echo "--- path B shaping ---"; head -6 "$R/shaping_b.log" 2>/dev/null
echo
echo "--- server saw which peer addresses? (from server stdout) ---"
cat "$R/server_stdout.log" 2>/dev/null | head -12

echo
echo "=============================================================="
echo "D. WHICH MigratedPath call site fires on the SERVER?"
echo "=============================================================="
echo "--- connection.go:915 context (client-side switchToNewPath) ---"
sed -n '905,930p' "$Q/connection.go" 2>/dev/null
echo
echo "--- connection.go:1295 context (server-side reactive) ---"
sed -n '1280,1300p' "$Q/connection.go" 2>/dev/null

echo
echo "=============================================================="
echo "E. Our harness: does the client verify the cutover honestly?"
echo "=============================================================="
grep -n -A6 "Switch()\|AddPath\|Probe(" /home/sivaa/pvseed/harness/quicgo/client/main.go 2>/dev/null | head -40

echo
echo "DONE"
