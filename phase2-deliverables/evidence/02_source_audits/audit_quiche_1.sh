#!/usr/bin/env bash
# EXHAUSTIVE quiche audit, part 1 -- source.
#
# THE CENTRAL QUESTION: quiche keeps PER-PATH congestion state. So is the
# 12,000 B observed at migration:
#   (i)  a RESET of an existing controller (like quic-go's MigratedPath), or
#   (ii) a NEW PATH object being created with a fresh controller?
# Both produce the same number but are different mechanisms, and the
# distinction matters for how the survey classifies quiche.
set -uo pipefail
Q=/home/sivaa/pvseed/quiche

echo "=============================================================="
echo "0. Commit + tree cleanliness"
echo "=============================================================="
git -C "$Q" rev-parse HEAD 2>/dev/null
git -C "$Q" describe --tags 2>/dev/null
echo "--- local modifications? (must be none) ---"
git -C "$Q" status --porcelain 2>/dev/null | grep -v '^??' | head -5 || echo "  clean"

echo
echo "=============================================================="
echo "1. Is there an explicit congestion RESET anywhere?"
echo "=============================================================="
grep -rn "fn reset" "$Q/quiche/src/recovery/" 2>/dev/null | head -20
echo "--- anything named like a migration reset? ---"
grep -rniE "on_path_change|migrat.*reset|reset.*migrat|path_migrat" \
    "$Q/quiche/src/" --include=*.rs 2>/dev/null | head -20

echo
echo "=============================================================="
echo "2. How is a new path's recovery/CC state created?"
echo "=============================================================="
echo "--- Path::new / recovery construction ---"
grep -rn "Recovery::new\|recovery: Recovery\|fn new(" "$Q/quiche/src/path.rs" 2>/dev/null | head -12
echo
echo "--- initial congestion window constant ---"
grep -rn "INITIAL_WINDOW\|initial_congestion_window\|INITIAL_WINDOW_PACKETS" \
    "$Q/quiche/src/recovery/"*.rs "$Q/quiche/src/recovery/**/*.rs" 2>/dev/null | head -12

echo
echo "=============================================================="
echo "3. RESET-vs-LOSS discriminator values"
echo "=============================================================="
echo "--- minimum congestion window ---"
grep -rn "MINIMUM_WINDOW\|minimum_window" "$Q/quiche/src/recovery/"*.rs 2>/dev/null | head -8
echo "--- cubic/reno loss reduction factor (beta) ---"
grep -rn "BETA\|beta\b\|LOSS_REDUCTION" "$Q/quiche/src/recovery/congestion/"*.rs 2>/dev/null | head -10
echo "--- default max datagram / pmtu ---"
grep -rn "MAX_SEND_UDP_PAYLOAD_SIZE\|DEFAULT_MAX_DATAGRAM\|max_datagram_size" \
    "$Q/quiche/src/lib.rs" 2>/dev/null | head -6

echo
echo "=============================================================="
echo "4. Q2 -- is the PATH_CHALLENGE/PATH_RESPONSE delay used for RTT?"
echo "=============================================================="
grep -rn "DEFAULT_INITIAL_RTT\|INITIAL_RTT" "$Q/quiche/src/" --include=*.rs 2>/dev/null | head -10
echo
echo "--- where PATH_RESPONSE is handled: does it touch RTT? ---"
grep -rn -A15 "PathResponse" "$Q/quiche/src/lib.rs" 2>/dev/null \
    | grep -iE "rtt|update_rtt|smoothed" | head -8 \
    || echo "  (no RTT reference near PathResponse handling)"

echo
echo "=============================================================="
echo "5. Q3 -- are ACKs attributed per-path? (structural exclusion)"
echo "=============================================================="
grep -rn "fn on_ack_received" "$Q/quiche/src/recovery/"*.rs 2>/dev/null | head -5
echo "--- does the connection route ACK processing through a specific path? ---"
grep -rn "paths.get_mut\|path.recovery\|recovery.on_ack_received" "$Q/quiche/src/lib.rs" 2>/dev/null | head -10

echo DONE
