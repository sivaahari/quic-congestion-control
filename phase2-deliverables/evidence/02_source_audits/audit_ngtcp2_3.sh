#!/usr/bin/env bash
# ngtcp2 audit part 3 -- what the reset actually does, where it fires on
# migration, the initial window, and the Q3 old-path question.
set -uo pipefail
N=/home/sivaa/pvseed/ngtcp2

echo "=============================================================="
echo "1. conn_reset_congestion_state -- does it reset RTT too?"
echo "=============================================================="
sed -n '6096,6130p' "$N/lib/ngtcp2_conn.c" 2>/dev/null

echo
echo "=============================================================="
echo "2. Call site 13892 -- is it really on the migration path?"
echo "=============================================================="
sed -n '13860,13900p' "$N/lib/ngtcp2_conn.c" 2>/dev/null

echo
echo "=============================================================="
echo "3. Call site 6188 -- path response / validation success"
echo "=============================================================="
sed -n '6154,6200p' "$N/lib/ngtcp2_conn.c" 2>/dev/null

echo
echo "=============================================================="
echo "4. Call site 5602 -- what event is this?"
echo "=============================================================="
sed -n '5580,5610p' "$N/lib/ngtcp2_conn.c" 2>/dev/null

echo
echo "=============================================================="
echo "5. Initial congestion window"
echo "=============================================================="
grep -rn "cwnd = \|cwnd_initial\|NGTCP2_DEFAULT_INITIAL\|initial_cwnd\b" \
    "$N/lib/ngtcp2_conn_stat.h" "$N/lib/ngtcp2_conn.c" 2>/dev/null | head -12
echo "--- ngtcp2_cc_compute_initcwnd ---"
grep -rn -A10 "ngtcp2_cc_compute_initcwnd" "$N/lib/ngtcp2_cc.c" 2>/dev/null | head -20

echo
echo "=============================================================="
echo "6. Q3 -- are old-path in-flight packets discarded on migration?"
echo "=============================================================="
grep -n "ngtcp2_rtb_remove_all\|rtb_remove\|conn_discard\|bytes_in_flight = 0" \
    "$N/lib/ngtcp2_conn.c" 2>/dev/null | head -12
echo
echo "--- does the rtb entry record which path it was sent on? ---"
grep -n "path\|pid" "$N/lib/ngtcp2_rtb.h" 2>/dev/null | grep -iE "struct|path" | head -12

echo
echo "=============================================================="
echo "7. §9.4 port-only exemption: does ngtcp2 distinguish?"
echo "=============================================================="
grep -rn "eq_addr\|addr_eq\|ngtcp2_addr_eq\|port" "$N/lib/ngtcp2_conn.c" 2>/dev/null \
    | grep -iE "migrat|path_chang|non_probing" | head -8 || echo "  (no port-specific branch found near migration)"
echo DONE
