#!/usr/bin/env bash
# Independent audit of the quic-go claims. They invert picoquic's result on
# Q1 and Q3, so they must be verified rather than accepted.
set -uo pipefail
Q=/home/sivaa/pvseed/quic-go

echo "=============================================================="
echo "0. Commit under audit"
echo "=============================================================="
git -C "$Q" rev-parse HEAD 2>/dev/null
git -C "$Q" describe --tags 2>/dev/null
echo "--- is the tree clean (no local edits that could fake a result)? ---"
git -C "$Q" status --porcelain 2>/dev/null | head -5 || echo "  clean"

echo
echo "=============================================================="
echo "Q1a. Does MigratedPath exist, and does it REPLACE the controller?"
echo "=============================================================="
awk '/func \(h \*sentPacketHandler\) MigratedPath/{f=1} f{print} f&&/^}/{exit}' \
    "$Q/internal/ackhandler/sent_packet_handler.go" 2>/dev/null

echo
echo "=============================================================="
echo "Q1b. Does ResetForPathMigration reset the RTT estimator?"
echo "=============================================================="
awk '/func \(r \*RTTStats\) ResetForPathMigration/{f=1} f{print} f&&/^}/{exit}' \
    "$Q/internal/utils/rtt_stats.go" 2>/dev/null

echo
echo "=============================================================="
echo "Q1c. Is MigratedPath actually REACHABLE? (all call sites)"
echo "=============================================================="
grep -rn "MigratedPath(" "$Q" --include=*.go 2>/dev/null | grep -v "_test.go"
echo "--- (test files, for completeness) ---"
grep -rn "MigratedPath(" "$Q" --include=*_test.go 2>/dev/null | head -3

echo
echo "=============================================================="
echo "Q3a. Does DeclareLost really NIL the packet (structural removal)?"
echo "=============================================================="
awk '/func \(h \*sentPacketHistory\) DeclareLost/{f=1} f{print} f&&/^}/{exit}' \
    "$Q/internal/ackhandler/sent_packet_history.go" 2>/dev/null

echo
echo "=============================================================="
echo "Q3b. Does the ACK-matching iterator skip nil entries?"
echo "=============================================================="
awk '/func \(h \*sentPacketHistory\) Packets/{f=1} f{print} f&&/^}/{exit}' \
    "$Q/internal/ackhandler/sent_packet_history.go" 2>/dev/null

echo
echo "=============================================================="
echo "Q2. Is initialRTT used for anything OTHER than probe backoff?"
echo "=============================================================="
grep -rn "initialRTT" "$Q" --include=*.go 2>/dev/null | grep -v "_test.go"
echo
echo "--- does ANY path-response handler touch rttStats? ---"
grep -rn -A12 "func.*HandlePathResponseFrame" "$Q" --include=*.go 2>/dev/null \
    | grep -iE "rtt|smoothed|UpdateRTT" || echo "  (NO rtt reference in any HandlePathResponseFrame -- Q2 = NO confirmed)"

echo
echo "=============================================================="
echo "Q1d. quic-go's initial congestion window (to check the 40960 claim)"
echo "=============================================================="
grep -rn "initialCongestionWindow\|InitialPacketSize\|initialMaxDatagramSize" \
    "$Q/internal/congestion/cubic_sender.go" "$Q/internal/protocol/params.go" 2>/dev/null | head -8

echo
echo "=============================================================="
echo "Q1e. DefaultInitialRTT (to check the 100ms claim)"
echo "=============================================================="
grep -rn "DefaultInitialRTT" "$Q/internal/utils/rtt_stats.go" 2>/dev/null | head -3

echo
echo "=============================================================="
echo "SANITY. Is there really no multipath in this tree?"
echo "=============================================================="
grep -ril "multipath" "$Q" --include=*.go 2>/dev/null | head -5 || echo "  no multipath references -- single migration code path"

echo
echo "DONE"
