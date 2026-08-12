#!/usr/bin/env bash
# Verify the quic-go LIVE measurement, and check one cross-check the agent
# did not call out: quic-go's first post-migration RTT sample should reflect
# the NEW path's delay (~40 ms). picoquic's reflected the OLD path (20.3 ms on
# a 60 ms path) because it fails Q3. If quic-go's lands near 40 ms, the Q3
# source finding is corroborated by independent runtime evidence.
set -uo pipefail
R=/home/sivaa/pvseed/results/raw/quicgo/migrate_demo

echo "=============== artefacts present? ==============="
find "$R" -maxdepth 2 -type f -printf '%-64p %10s B\n' 2>/dev/null | sed "s|/home/sivaa/pvseed/||" | head -20

echo
echo "=============== server metrics CSV: head ==============="
head -3 "$R/server_metrics.csv" 2>/dev/null

echo
echo "=============== analysis ==============="
python3 - <<'PYEOF'
import csv, os
R = "/home/sivaa/pvseed/results/raw/quicgo/migrate_demo"
p = os.path.join(R, "server_metrics.csv")
if not os.path.exists(p):
    print("  server_metrics.csv MISSING"); raise SystemExit
rows = []
with open(p) as f:
    for r in csv.DictReader(f):
        try:
            rows.append({k: (float(v) if v not in ("", None) else None) for k, v in r.items()
                         if k in ("time_us","cwnd","bytes_in_flight","smoothed_rtt","min_rtt","latest_rtt")})
        except ValueError:
            pass
rows = [r for r in rows if r.get("time_us") is not None]
rows.sort(key=lambda r: r["time_us"])
print(f"  {len(rows)} metric samples")

QG_IW = 32 * 1280   # initialCongestionWindow(32) * InitialPacketSize(1280) = 40960
cw = [r for r in rows if r.get("cwnd")]
if cw:
    mn = min(cw, key=lambda r: r["cwnd"])
    print(f"  min cwnd overall : {mn['cwnd']:,.0f} B  at t={mn['time_us']:,.0f} us")
    print(f"  quic-go initial W: {QG_IW:,} B   -> min is {mn['cwnd']/QG_IW:.2f}x initial")
    print("  VERDICT: RESET OCCURRED" if mn["cwnd"] <= QG_IW*1.05 else "  VERDICT: NO RESET")

# find the migration discontinuity: the largest gap in sample times
srtt = [r for r in rows if r.get("smoothed_rtt")]
if len(srtt) > 2:
    gaps = [(srtt[i+1]["time_us"]-srtt[i]["time_us"], i) for i in range(len(srtt)-1)]
    biggest, idx = max(gaps)
    before, after = srtt[idx], srtt[idx+1]
    print(f"\n  largest sampling gap: {biggest/1000:.1f} ms  (the migration stall)")
    print(f"  last  srtt BEFORE: {before['smoothed_rtt']:>9,.0f} us = {before['smoothed_rtt']/1000:6.1f} ms")
    print(f"  first srtt AFTER : {after['smoothed_rtt']:>9,.0f} us = {after['smoothed_rtt']/1000:6.1f} ms")
    tri = [after.get("smoothed_rtt"), after.get("min_rtt"), after.get("latest_rtt")]
    if all(v is not None for v in tri):
        print(f"  after: srtt={tri[0]:,.0f}  min={tri[1]:,.0f}  latest={tri[2]:,.0f}")
        if len({round(v) for v in tri}) == 1:
            print("  -> all three IDENTICAL = fingerprint of a from-scratch first sample")
    print("\n  CROSS-CHECK (the important one):")
    print("    path A delay 20 ms, path B delay 40 ms.")
    print(f"    first post-migration sample = {after['smoothed_rtt']/1000:.1f} ms")
    v = after["smoothed_rtt"]/1000
    if 30 <= v <= 55:
        print("    -> reflects the NEW path. Old-path ACKs were excluded. Q3=YES corroborated.")
    elif 12 <= v <= 28:
        print("    -> reflects the OLD path. Would CONTRADICT the Q3=YES source finding.")
    else:
        print("    -> inconclusive; inspect manually.")
PYEOF
echo
echo "DONE"
