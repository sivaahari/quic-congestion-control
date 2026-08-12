#!/usr/bin/env bash
# ngtcp2 audit part 2 -- THE DEAD-HOOK CHECK plus the missing constants.
set -uo pipefail
N=/home/sivaa/pvseed/ngtcp2

echo "=============================================================="
echo "1. What is the cc reset callback FOR? (its own doc comment)"
echo "=============================================================="
sed -n '190,205p' "$N/lib/ngtcp2_cc.h" 2>/dev/null

echo
echo "=============================================================="
echo "2. IS IT EVER CALLED? every dispatch of ->reset / .reset"
echo "=============================================================="
echo "--- direct calls through the cc struct ---"
grep -rn "cc\.reset(\|cc->reset(\|->reset(&\|reset(&conn->cc" "$N/lib" 2>/dev/null | head -20
echo
echo "--- any call at all, excluding the definitions themselves ---"
grep -rnE "\breset\(" "$N/lib"/*.c 2>/dev/null \
  | grep -vE "static void |^.*:void ngtcp2_cc_|cc_reset\(ngtcp2_cc|_cc_reset\(cc|reno_cc_reset\(reno|cubic_cc_reset\(cubic|bbr_cc_reset" \
  | head -20
echo
echo "--- named wrappers around it ---"
grep -rn "ngtcp2_conn_cc_reset\|conn_cc_reset\|cc_reset" "$N/lib/ngtcp2_conn.c" 2>/dev/null | head -12

echo
echo "=============================================================="
echo "3. What runs when path validation SUCCEEDS? (the migration completes)"
echo "=============================================================="
grep -n "conn_on_path_validated\|pv_succeed\|NGTCP2_PV_FLAG\|conn_reset_congestion_state\|conn_recv_path_response" \
    "$N/lib/ngtcp2_conn.c" 2>/dev/null | head -16

echo
echo "--- conn_reset_congestion_state, if it exists ---"
awk '/conn_reset_congestion_state\(ngtcp2_conn/{f=1} f{print NR": "$0} f&&/^}/{exit}' \
    "$N/lib/ngtcp2_conn.c" 2>/dev/null | head -45

echo
echo "--- and who calls it? ---"
grep -rn "conn_reset_congestion_state(" "$N/lib" 2>/dev/null | head -12

echo
echo "=============================================================="
echo "4. Discriminator constants"
echo "=============================================================="
grep -rn "define NGTCP2_INITIAL_CWND\|initial_cwnd\|NGTCP2_MIN_CWND\|min_cwnd" \
    "$N/lib/"*.h "$N/lib/"*.c 2>/dev/null | head -14
echo "--- cubic beta / multiplicative decrease ---"
grep -rn "0\.7\|7 /\|/ 10\|BETA" "$N/lib/ngtcp2_cc.c" 2>/dev/null | head -12

echo
echo "=============================================================="
echo "5. Q3: does the RTT update know which path an ACK came from?"
echo "=============================================================="
grep -rn "ngtcp2_conn_update_rtt" "$N/lib/"*.c 2>/dev/null | head -8
echo "--- callers of update_rtt: is there a path check? ---"
for L in $(grep -n "ngtcp2_conn_update_rtt(" "$N/lib/ngtcp2_conn.c" 2>/dev/null | cut -d: -f1 | head -3); do
    echo "  === around line $L ==="
    sed -n "$((L-16)),$((L+3))p" "$N/lib/ngtcp2_conn.c"
done
echo DONE
