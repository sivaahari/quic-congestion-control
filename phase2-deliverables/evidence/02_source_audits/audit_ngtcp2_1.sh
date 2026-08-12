#!/usr/bin/env bash
# ngtcp2 source audit -- Q1/Q2/Q3, the dead-hook check, and the
# reset-vs-loss discriminator constants.
set -uo pipefail
N=/home/sivaa/pvseed/ngtcp2

echo "=============================================================="
echo "0. Commit + cleanliness"
echo "=============================================================="
git -C "$N" rev-parse HEAD 2>/dev/null
git -C "$N" describe --tags 2>/dev/null
git -C "$N" status --porcelain 2>/dev/null | grep -v '^??' | head -5 || echo "  clean"

echo
echo "=============================================================="
echo "1. Migration API surface"
echo "=============================================================="
grep -rn "ngtcp2_conn_initiate_migration\|ngtcp2_conn_initiate_immediate_migration" \
    "$N/lib/includes/ngtcp2/ngtcp2.h" 2>/dev/null | head -6
echo "--- implementations ---"
grep -rn "^ngtcp2_conn_initiate_migration\|^ngtcp2_conn_initiate_immediate_migration\|conn_initiate_migration" \
    "$N/lib/ngtcp2_conn.c" 2>/dev/null | head -8

echo
echo "=============================================================="
echo "2. THE DEAD-HOOK CHECK: is there a CC reset, and is it called?"
echo "=============================================================="
echo "--- the ngtcp2_cc callback struct ---"
grep -n "ngtcp2_cc_reset\|reset;\|ngtcp2_cc_base" "$N/lib/includes/ngtcp2/ngtcp2.h" 2>/dev/null | head -12
echo
echo "--- every definition/reference of a cc reset ---"
grep -rn "cc_reset\|->reset(\|\.reset =" "$N/lib" 2>/dev/null | grep -v "_test" | head -20

echo
echo "=============================================================="
echo "3. Q1: what happens to congestion state on migration?"
echo "=============================================================="
echo "--- conn_initiate_migration body ---"
awk '/conn_initiate_migration\(ngtcp2_conn/{f=1} f{print NR": "$0} f&&/^}/{exit}' \
    "$N/lib/ngtcp2_conn.c" 2>/dev/null | head -60

echo
echo "--- where the active path is switched (server side too) ---"
grep -rn "conn_recv_non_probing_pkt_on_new_path\|ngtcp2_conn_set_remote_addr\|conn_on_path_validated\|path_challenge" \
    "$N/lib/ngtcp2_conn.c" 2>/dev/null | head -14

echo
echo "=============================================================="
echo "4. Discriminator constants"
echo "=============================================================="
grep -rn "NGTCP2_INITIAL_CWND\|NGTCP2_MIN_CWND\|NGTCP2_MAX_DGRAM\|NGTCP2_DEFAULT_MAX_PKTLEN\|NGTCP2_MAX_UDP_PAYLOAD" \
    "$N/lib/"*.h "$N/lib/includes/ngtcp2/"*.h 2>/dev/null | grep define | head -12
echo "--- cubic / reno loss reduction ---"
grep -rn "0\.7\|NGTCP2_CUBIC_BETA\|BETA" "$N/lib/ngtcp2_cc.c" 2>/dev/null | head -10

echo
echo "=============================================================="
echo "5. Q2: does path validation feed the RTT estimator?"
echo "=============================================================="
grep -rn "PATH_RESPONSE\|path_response" "$N/lib/ngtcp2_conn.c" 2>/dev/null | head -12
echo "--- does any of that touch rtt? ---"
grep -rn -A8 "conn_recv_path_response" "$N/lib/ngtcp2_conn.c" 2>/dev/null \
    | grep -iE "rtt|smoothed|update_rtt" | head -8 || echo "  (no RTT reference near PATH_RESPONSE handling)"

echo
echo "=============================================================="
echo "6. Q3: are ACK-derived samples attributed per path?"
echo "=============================================================="
grep -rn "ngtcp2_conn_update_rtt\|update_rtt(" "$N/lib/"*.c 2>/dev/null | head -10
echo "--- is there any path id on sent packets? ---"
grep -rn "path.*id\|pktns\|ngtcp2_rtb_entry" "$N/lib/ngtcp2_rtb.h" 2>/dev/null | head -12
echo DONE
