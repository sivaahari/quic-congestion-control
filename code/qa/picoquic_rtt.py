#!/usr/bin/env python3
"""Per-rep RTT behaviour across the migration.

Path A carries a 20 ms one-way delay and path B 40 ms, applied to the down
direction only, so the true RTTs are ~20 ms and ~40 ms. If picoquic excluded
old-path samples (Q3), the estimator would move to ~40 ms promptly. If it does
not, stale path-A acknowledgements hold it near 20 ms first.
"""
import csv
import os

R = "/home/sivaa/pvseed/results/raw/picoquic/reps"
MIG_END = 5_030_000   # path_* frames finish by ~5.023 s in every rep

print(f"{'rep':>4}  {'srtt before':>12}  {'first srtt after':>17}  {'srtt @ +1 s':>12}  {'srtt final':>11}")
print("-" * 68)
rows_out = []
for i in range(1, 6):
    f = f"{R}/rep_{i}/server_metrics.csv"
    if not os.path.exists(f):
        continue
    pts = []
    for row in csv.DictReader(open(f)):
        try:
            t, s = float(row["time_us"]), float(row["smoothed_rtt"])
        except Exception:
            continue
        if s > 0:
            pts.append((t, s))
    before = [s for t, s in pts if t < 4_980_000]
    after = [(t, s) for t, s in pts if t > MIG_END]
    if not before or not after:
        continue
    b = before[-1] / 1000
    fa = after[0][1] / 1000
    at1 = next((s / 1000 for t, s in after if t > MIG_END + 1_000_000), float("nan"))
    fin = after[-1][1] / 1000
    rows_out.append((b, fa, at1, fin))
    print(f"{i:>4}  {b:>10.2f} ms  {fa:>15.2f} ms  {at1:>10.2f} ms  {fin:>9.2f} ms")

if rows_out:
    n = len(rows_out)
    print("-" * 68)
    print(f"{'mean':>4}  {sum(r[0] for r in rows_out)/n:>10.2f} ms  "
          f"{sum(r[1] for r in rows_out)/n:>15.2f} ms  "
          f"{sum(r[2] for r in rows_out)/n:>10.2f} ms  "
          f"{sum(r[3] for r in rows_out)/n:>9.2f} ms")
    print(f"\n  path A true RTT ~20 ms, path B (new) true RTT ~40 ms")
    fa_lo = min(r[1] for r in rows_out); fa_hi = max(r[1] for r in rows_out)
    print(f"  first srtt after migration spans {fa_lo:.2f}-{fa_hi:.2f} ms")
    print(f"  -> closer to the {'OLD' if abs(sum(r[1] for r in rows_out)/n - 20) < abs(sum(r[1] for r in rows_out)/n - 40) else 'NEW'} path")
