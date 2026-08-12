#!/usr/bin/env python3
"""The window IMMEDIATELY after the migration completes, per rep.

For the other four implementations the recorded "after" value is what the window
became AT the migration -- exactly their initial window. The comparable quantity
for picoquic is therefore the window just after path validation completes, not
the loss-driven minimum reached ~110 ms later. Both are recorded; only the
former is comparable across implementations.
"""
import csv
import glob
import json
import os

R = "/home/sivaa/pvseed/results/raw/picoquic/reps"

print(f"{'rep':>4} {'mig ends (us)':>14} {'window just after':>18} {'min later':>11} {'min at (ms)':>12}")
print("-" * 66)
firsts, mins = [], []
for i in range(1, 6):
    qs = sorted(glob.glob(f"{R}/rep_{i}/qlog_server/*.qlog"),
                key=os.path.getsize, reverse=True)
    csvf = f"{R}/rep_{i}/server_metrics.csv"
    if not qs or not os.path.exists(csvf):
        continue
    with open(qs[0]) as fh:
        tr = json.load(fh)["traces"][0]
    fl = tr["event_fields"]
    ti, ni, di = fl.index("relative_time"), fl.index("event"), fl.index("data")
    resp = []
    for ev in tr["events"]:
        d = ev[di]
        if isinstance(d, dict) and ev[ni] == "packet_received":
            for fr in d.get("frames") or []:
                if fr.get("frame_type") == "path_response":
                    resp.append(float(ev[ti]))
    if not resp:
        continue
    t_end = max(resp)
    pts = []
    for row in csv.DictReader(open(csvf)):
        try:
            pts.append((float(row["time_us"]), float(row["cwnd"])))
        except Exception:
            pass
    after = [(t, c) for t, c in pts if t > t_end]
    if not after:
        continue
    first = after[0][1]
    lo = min(c for _, c in after[:400])
    lo_t = [t for t, c in after[:400] if c == lo][0]
    firsts.append(first)
    mins.append(lo)
    print(f"{i:>4} {t_end:>14,.0f} {first:>16,.0f} B {lo:>9,.0f} B {(lo_t-t_end)/1000:>10.0f}")

if firsts:
    print("-" * 66)
    print(f"  window just after migration : {min(firsts):,.0f} - {max(firsts):,.0f} B")
    print(f"  later loss-driven minimum   : {min(mins):,.0f} - {max(mins):,.0f} B")
    print(f"  a reset would have produced : 14,240 B (10 x 1424) or 15,360 B (constant)")
