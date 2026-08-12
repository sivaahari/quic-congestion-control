#!/usr/bin/env bash
# cwnd is logged only when it CHANGES, so anchoring on RTT samples mislabels
# things. Look at the cwnd series directly across the migration.
set -uo pipefail

python3 - <<'PYEOF'
import csv, os
R = "/home/sivaa/pvseed/results/raw/quicgo/migrate_demo"
cw = []
with open(os.path.join(R, "server_metrics.csv")) as f:
    for r in csv.DictReader(f):
        t, c = r.get("time_us"), r.get("cwnd")
        if t and c:
            cw.append((float(t), float(c)))
cw.sort()
QG_IW = 32 * 1280
print(f"{len(cw)} cwnd samples total\n")

print("cwnd samples between t=4.0 s and t=6.0 s (the migration is ~5.03 s):")
print(f"  {'t (s)':>9}  {'cwnd (B)':>12}  {'xIW':>6}")
win = [(t, c) for t, c in cw if 4.0e6 <= t <= 6.0e6]
for t, c in win:
    print(f"  {t/1e6:9.4f}  {c:12,.0f}  {c/QG_IW:6.2f}")

if win:
    pre = [(t, c) for t, c in win if t < 5.03e6]
    post = [(t, c) for t, c in win if t >= 5.03e6]
    print()
    if pre:
        print(f"  peak cwnd BEFORE migration : {max(c for _, c in pre):,.0f} B")
        print(f"  last cwnd BEFORE migration : {pre[-1][1]:,.0f} B  (t={pre[-1][0]/1e6:.4f} s)")
    if post:
        print(f"  first cwnd AFTER migration : {post[0][1]:,.0f} B  (t={post[0][0]/1e6:.4f} s)")
        print(f"  = {post[0][1]/QG_IW:.2f}x the initial window ({QG_IW:,} B)")
        print()
        if post[0][1] <= QG_IW * 1.05:
            print("  CONFIRMED: cwnd collapses to the initial window at migration.")
        else:
            print("  NOT CONFIRMED at the first post-migration sample.")
PYEOF
echo
echo "DONE"
