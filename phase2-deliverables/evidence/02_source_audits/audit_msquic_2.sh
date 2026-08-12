#!/usr/bin/env bash
# msquic audit part 2 -- the pieces cut off / mis-matched in part 1.
set -uo pipefail
M=/home/sivaa/pvseed/msquic/src/core

echo "=============================================================="
echo "A. The REAL QuicPathSetActive definition (part 1 matched a caller)"
echo "=============================================================="
DEF=$(grep -n "^QuicPathSetActive" "$M/path.c" 2>/dev/null | head -1 | cut -d: -f1)
echo "  definition starts at line $DEF"
[ -n "$DEF" ] && sed -n "$((DEF-6)),$((DEF+52))p" "$M/path.c"

echo
echo "=============================================================="
echo "B. Q3-B: context of BOTH QuicCongestionControlOnDataAcknowledged sites"
echo "   (claim: bytes-acked are accumulated with NO PathId filter)"
echo "=============================================================="
for L in 1206 1619; do
    echo "  ================ loss_detection.c : $L ================"
    sed -n "$((L-26)),$((L+3))p" "$M/loss_detection.c"
    echo
done

echo "  --- does AckEvent carry any path scoping at all? ---"
grep -n "AckEvent\." "$M/loss_detection.c" 2>/dev/null | sed -n '1,25p'
echo
echo "  --- QUIC_ACK_EVENT fields (is there a PathId?) ---"
awk '/typedef struct QUIC_ACK_EVENT/{f=1} f{print} f&&/} QUIC_ACK_EVENT/{exit}' \
    "$M/congestion_control.h" 2>/dev/null | head -40

echo
echo "=============================================================="
echo "C. Discriminator constants"
echo "=============================================================="
grep -rn "QUIC_INITIAL_WINDOW_PACKETS\|QUIC_PERSISTENT_CONGESTION_WINDOW_PACKETS\|TEN_TIMES_BETA_CUBIC\|QUIC_INITIAL_RTT\b" \
    "$M/../inc/quic_platform.h" "$M/"*.h "$M/../inc/"*.h 2>/dev/null | grep define | head -12

echo
echo "=============================================================="
echo "D. Q2 -- PATH_RESPONSE handling and QuicPathSetValid"
echo "=============================================================="
grep -n -A12 "QUIC_FRAME_PATH_RESPONSE:" "$M/connection.c" 2>/dev/null | head -20
echo "  --- QuicPathSetValid body ---"
VDEF=$(grep -n "^QuicPathSetValid" "$M/path.c" 2>/dev/null | head -1 | cut -d: -f1)
[ -n "$VDEF" ] && sed -n "$((VDEF)),$((VDEF+34))p" "$M/path.c"
echo
echo "  --- any RTT write anywhere in path validation? ---"
grep -n "SmoothedRtt\|MinRtt\|RttVariance" "$M/path.c" 2>/dev/null | head -10
echo DONE
