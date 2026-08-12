#!/usr/bin/env bash
set -uo pipefail
LOG=/home/sivaa/pvseed/_build/full_test_output.log
OUT=/home/sivaa/pvseed/_build/test_subset_report.txt

: > "$OUT"

MIGRATION_TESTS="sockloop_migration migration migration_long migration_with_loss migration_zero migration_fail false_migration migration_disabled migration_controlled migration_mtu_drop"
CC_TESTS="cubic cubic_jitter fastcc fastcc_jitter bbr bbr_jitter bbr_long bbr_performance bbr_slow_long bbr_one_second bbr_gbps bbr_asym100 bbr_asym100_nodelay bbr_asym400 bbr1 bbr1_long l4s_prague l4s_prague_updown l4s_bbr l4s_reno l4s_bbr_updown long_rtt high_latency_bbr high_latency_cubic high_latency_probeRTT satellite_seeded_bbr1 satellite_bbr1 satellite_cubic satellite_cubic_seeded satellite_cubic_loss satellite_dcubic_seeded satellite_prague_seeded bdp_rtt bdp_reno bdp_cubic bdp_bbr1 limited_reno limited_cubic limited_bbr app_limit_cc app_limited_bbr app_limited_bbr_post_idle app_limited_cubic app_limited_reno wifi_bbr wifi_bbr_hard wifi_bbr_long wifi_bbr_many wifi_bbr_shadow wifi_bbr1 wifi_bbr1_hard wifi_bbr1_long wifi_reno wifi_reno_hard wifi_reno_long wifi_cubic wifi_cubic_hard wifi_cubic_long mtu_drop_bbr mtu_drop_cubic mtu_drop_dcubic mtu_drop_newreno red_bbr red_cubic red_dcubic red_newreno pacing_bbr pacing_cubic pacing_dcubic pacing_newreno datagram_app_limited_bbr netperf_bbr tls_api_very_long_congestion gbps_performance cc_compete"

echo "=== MIGRATION-RELATED TESTS ===" >> "$OUT"
for t in $MIGRATION_TESTS; do
    line=$(grep -A1 ", $t\$" "$LOG" | tail -1)
    started=$(grep -c ", $t\$" "$LOG")
    if [ "$started" -eq 0 ]; then
        echo "$t: NOT FOUND IN TEST TABLE (name mismatch?)" >> "$OUT"
    else
        echo "$t: $line" >> "$OUT"
    fi
done

echo "" >> "$OUT"
echo "=== CONGESTION-CONTROL-RELATED TESTS ===" >> "$OUT"
for t in $CC_TESTS; do
    started=$(grep -c ", $t\$" "$LOG")
    if [ "$started" -eq 0 ]; then
        echo "$t: NOT FOUND IN TEST TABLE (name mismatch?)" >> "$OUT"
    else
        line=$(grep -A1 ", $t\$" "$LOG" | tail -1)
        echo "$t: $line" >> "$OUT"
    fi
done

cat "$OUT"
