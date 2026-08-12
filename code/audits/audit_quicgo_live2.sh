#!/usr/bin/env bash
# CORRECTION to the previous check: "minimum cwnd overall" is meaningless here,
# because the connection legitimately starts at the initial window. The reset
# claim must be tested in a window AROUND the migration instant only.
set -uo pipefail

python3 - <<'PYEOF'
import csv, os
R = "/home/sivaa/pvseed/results/raw/quicgo/migrate_demo"
rows = []
with open(os.path.join(R, "server_metrics.csv")) as f:
    for r in csv.DictReader(f):
        d = {}
        for k in ("time_us","cwnd","bytes_in_flight","smoothed_rtt","min_rtt","latest_rtt"):
            v = r.get(k)
            d[k] = float(v) if v not in ("", None) else None
        if d["time_us"] is not None:
            rows.append(d)
rows.sort(key=lambda r: r["time_us"])
QG_IW = 32 * 1280

# Locate the migration by the largest gap in RTT sampling (the stall).
srtt = [r for r in rows if r["smoothed_rtt"]]
gaps = [(srtt[i+1]["time_us"] - srtt[i]["time_us"], i) for i in range(len(srtt)-1)]
gap, idx = max(gaps)
t_mig = srtt[idx+1]["time_us"]
print(f"migration instant (first sample after the {gap/1000:.1f} ms stall): t = {t_mig/1e6:.3f} s\n")

cw = [r for r in rows if r["cwnd"]]
def window(a, b):
    return [r for r in cw if a <= r["time_us"] <= b]

pre  = [r for r in cw if r["time_us"] < t_mig]
post = window(t_mig - 50_000, t_mig + 2_000_000)   # -50 ms .. +2 s around migration

print(f"cwnd just BEFORE migration : {pre[-1]['cwnd']:>10,.0f} B   (t={pre[-1]['time_us']/1e6:.3f} s)")
if post:
    mn = min(post, key=lambda r: r["cwnd"])
    print(f"cwnd MIN in migration window: {mn['cwnd']:>10,.0f} B   (t={mn['time_us']/1e6:.3f} s)")
    print(f"quic-go initial window      : {QG_IW:>10,} B   -> {mn['cwnd']/QG_IW:.2f}x initial")
    print()
    if mn["cwnd"] <= QG_IW * 1.05:
        print("VERDICT: RESET OCCURRED AT MIGRATION (cwnd returned to the initial window)")
    else:
        print("VERDICT: NO RESET AT MIGRATION -- would CONTRADICT the source finding")

# Show the samples immediately around it so the shape is visible, not inferred.
print("\nsamples spanning the migration:")
print(f"  {'t (s)':>9}  {'cwnd (B)':>10}  {'srtt (ms)':>10}")
span = [r for r in rows if t_mig - 120_000 <= r["time_us"] <= t_mig + 400_000]
shown = 0
for r in span:
    if r["cwnd"] is None and r["smoothed_rtt"] is None:
        continue
    c = f"{r['cwnd']:,.0f}" if r["cwnd"] else "-"
    s = f"{r['smoothed_rtt']/1000:.1f}" if r["smoothed_rtt"] else "-"
    mark = "  <-- migration" if abs(r["time_us"] - t_mig) < 1 else ""
    print(f"  {r['time_us']/1e6:9.4f}  {c:>10}  {s:>10}{mark}")
    shown += 1
    if shown >= 22:
        break
PYEOF
echo
echo "DONE"
