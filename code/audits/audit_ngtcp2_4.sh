#!/usr/bin/env bash
# ngtcp2 audit part 4 -- the Q3 watermark mechanism, the initial window,
# whether RTT is reset, and whether the built examples can drive a live trial.
set -uo pipefail
N=/home/sivaa/pvseed/ngtcp2

echo "=============================================================="
echo "1. Q3 MECHANISM: ngtcp2_rtb_reset_cc_state (packet-number watermark)"
echo "=============================================================="
awk '/^void ngtcp2_rtb_reset_cc_state/{f=1} f{print NR": "$0} f&&/^}/{exit}' \
    "$N/lib/ngtcp2_rtb.c" 2>/dev/null | head -30
echo "--- what is cc_pkt_num used for? ---"
grep -n "cc_pkt_num" "$N/lib/ngtcp2_rtb.c" "$N/lib/ngtcp2_rtb.h" 2>/dev/null | head -12

echo
echo "=============================================================="
echo "2. Does the reset also clear RTT? (conn_reset_conn_stat_cc)"
echo "=============================================================="
awk '/conn_reset_conn_stat_cc\(ngtcp2_conn/{f=1} f{print NR": "$0} f&&/^}/{exit}' \
    "$N/lib/ngtcp2_conn.c" 2>/dev/null | head -30
echo "--- and reset_conn_stat_recovery / smoothed_rtt handling ---"
grep -n "smoothed_rtt = \|min_rtt = \|first_rtt_sample" "$N/lib/ngtcp2_conn.c" 2>/dev/null | head -12

echo
echo "=============================================================="
echo "3. Initial congestion window"
echo "=============================================================="
awk '/ngtcp2_cc_compute_initcwnd/{f=1} f{print NR": "$0} f&&/^}/{exit}' \
    "$N/lib/ngtcp2_cc.c" 2>/dev/null | head -20
grep -rn "NGTCP2_MAX_CWND\|NGTCP2_MIN_INITIAL_CWND\|compute_initcwnd" \
    "$N/lib/"*.c "$N/lib/"*.h 2>/dev/null | head -10

echo
echo "=============================================================="
echo "4. CAN THE BUILT EXAMPLES DRIVE A LIVE TRIAL?"
echo "=============================================================="
CLI=$N/build/examples/ptlsclient
SRV=$N/build/examples/ptlsserver
echo "  client: $CLI"; [ -x "$CLI" ] && echo "    executable OK"
echo "  server: $SRV"; [ -x "$SRV" ] && echo "    executable OK"
echo
echo "--- client options relevant to migration / qlog ---"
"$CLI" --help 2>&1 | grep -iE "change-local-addr|migrat|nat-rebinding|qlog|--cc|delay-stream|exit-on" | head -20
echo
echo "--- server options ---"
"$SRV" --help 2>&1 | grep -iE "qlog|--cc|max-data|help" | head -10

echo
echo "=============================================================="
echo "5. §9.4 port-only exemption: any special-casing?"
echo "=============================================================="
grep -rn "conn_recv_non_probing_pkt_on_new_path" "$N/lib/ngtcp2_conn.c" 2>/dev/null | head -4
awk '/conn_recv_non_probing_pkt_on_new_path\(ngtcp2_conn/{f=1} f{print NR": "$0} f&&/^}/{exit}' \
    "$N/lib/ngtcp2_conn.c" 2>/dev/null | grep -iE "port|addr_eq|eq_addr|local|remote" | head -12
echo DONE
