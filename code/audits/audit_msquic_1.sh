#!/usr/bin/env bash
# EXHAUSTIVE msquic audit, part 1 -- source.
#
# Two claims are novel enough to be paper highlights and must be verified hard:
#   Q1 ASYMMETRIC: the migration INITIATOR (client) does not reset, but the
#                  OBSERVER (server, the data sender for a download) does.
#   Q3 SPLIT:      RTT samples ARE excluded by path id, but bytes-acked fed to
#                  the congestion controller are NOT.
set -uo pipefail
M=/home/sivaa/pvseed/msquic

echo "=============================================================="
echo "0. Commit + tree cleanliness"
echo "=============================================================="
git -C "$M" rev-parse HEAD 2>/dev/null
echo "--- modifications (submodule pointers are expected/benign) ---"
git -C "$M" status --porcelain 2>/dev/null | head -8
echo "--- version ---"
grep -m1 -o '"[0-9]\+\.[0-9]\+\.[0-9]\+"' "$M/version.json" 2>/dev/null

echo
echo "=============================================================="
echo "1. EVERY call site of QuicCongestionControlReset"
echo "=============================================================="
grep -rn "QuicCongestionControlReset" "$M/src" 2>/dev/null

echo
echo "=============================================================="
echo "2. QuicPathSetActive -- the UdpPortChangeOnly gate"
echo "=============================================================="
awk '/QuicPathSetActive\(/{f=1} f{print NR": "$0} f&&/^}/{exit}' "$M/src/core/path.c" 2>/dev/null | head -55

echo
echo "=============================================================="
echo "3. Who calls QuicPathSetActive?"
echo "=============================================================="
grep -rn "QuicPathSetActive(" "$M/src" 2>/dev/null | grep -v "^.*path\.c:[0-9]*:_IRQL\|QuicPathSetActive($"

echo
echo "=============================================================="
echo "4. CLIENT path: does QUIC_PARAM_CONN_LOCAL_ADDRESS reset anything?"
echo "=============================================================="
awk '/case QUIC_PARAM_CONN_LOCAL_ADDRESS:/{f=1; n=0} f{print NR": "$0; n++} f&&n>75{exit}' \
    "$M/src/core/connection.c" 2>/dev/null | grep -nE "Reset|PathSetActive|CongestionControl|LocalAddress|Binding|memcpy|QuicPathInit" | head -20
echo "  -> if no CongestionControlReset / PathSetActive appears above, the"
echo "     initiator does NOT reset its own congestion state."

echo
echo "=============================================================="
echo "5. Q3 part A -- is RTT excluded by path id?"
echo "=============================================================="
sed -n '1430,1450p' "$M/src/core/loss_detection.c" 2>/dev/null
echo "  ---- the gate that uses it ----"
sed -n '1495,1512p' "$M/src/core/loss_detection.c" 2>/dev/null

echo
echo "=============================================================="
echo "6. Q3 part B -- are bytes-acked filtered by path id? (the claim: NO)"
echo "=============================================================="
grep -rn "QuicCongestionControlOnDataAcknowledged" "$M/src" 2>/dev/null
echo "  ---- context of each call site ----"
for L in $(grep -n "QuicCongestionControlOnDataAcknowledged" "$M/src/core/loss_detection.c" 2>/dev/null | cut -d: -f1); do
    echo "  === loss_detection.c around line $L ==="
    sed -n "$((L-14)),$((L+4))p" "$M/src/core/loss_detection.c" 2>/dev/null
done

echo
echo "=============================================================="
echo "7. Discriminator constants"
echo "=============================================================="
grep -rn "QUIC_INITIAL_WINDOW_PACKETS\|QUIC_PERSISTENT_CONGESTION_WINDOW_PACKETS\|TEN_TIMES_BETA_CUBIC\|QUIC_INITIAL_RTT" \
    "$M/src/core/"*.h "$M/src/inc/"*.h 2>/dev/null | head -12

echo
echo "=============================================================="
echo "8. Q2 -- does PATH_RESPONSE handling touch RTT?"
echo "=============================================================="
grep -rn -A10 "QUIC_FRAME_PATH_RESPONSE:" "$M/src/core/connection.c" 2>/dev/null | head -22
echo "--- QuicPathSetValid: what does it actually set? ---"
awk '/QuicPathSetValid\(/{f=1} f{print} f&&/^}/{exit}' "$M/src/core/path.c" 2>/dev/null | head -30
echo DONE
