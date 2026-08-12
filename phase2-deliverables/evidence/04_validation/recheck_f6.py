#!/usr/bin/env python3
"""recheck_f6.py -- resolve the one FAIL from the fresh validation run.

The fresh validator tested F6 with a crude proxy: "all srtt samples in the last
two thirds of the trace equal 333000". For rep 5 -- which migrated late (~7.5 s)
and crashed early (~8.6 s) -- that window necessarily includes PRE-migration
samples, which are legitimately not 333000. That would produce a false FAIL.

This re-tests it properly: locate the migration instant per rep from the cwnd
series, then examine only samples strictly after it. Independent parsing again.
"""
import glob
import os
import re

ROOT = "/home/sivaa/pvseed"
IW = 12200        # msquic initial window, 10 x 1220
INITIAL_RTT = 333000
SENTINEL = 4294967295

print("=" * 72)
print("F6 RE-TEST, migration-anchored (resolves the fresh-run FAIL)")
print("=" * 72)

line_rx = re.compile(r"t_us=(\d+).*?\bcwnd=(\d+).*?\bsrtt_us=(\d+).*?\bmin_rtt_us=(\d+)")

total_reps = 0
pinned_reps = 0
for d in sorted(glob.glob(f"{ROOT}/results/raw/msquic/migrate_demo/rep_*")):
    log = os.path.join(d, "server.log")
    if not os.path.exists(log):
        continue
    total_reps += 1
    rows = []
    with open(log, errors="ignore") as fh:
        for line in fh:
            m = line_rx.search(line)
            if m:
                rows.append(tuple(int(x) for x in m.groups()))   # t, cwnd, srtt, min_rtt
    rows.sort()
    name = os.path.basename(d)
    if not rows:
        print(f"  {name}: no parsable stat lines")
        continue

    # migration instant = first sample at exactly the initial window after 4 s
    mig = next((t for t, c, s, mr in rows if c == IW and t > 4_000_000), None)
    if mig is None:
        print(f"  {name}: migration instant not located (no cwnd == {IW:,} after 4 s)")
        continue

    post = [(t, s, mr) for t, c, s, mr in rows if t > mig]
    if not post:
        print(f"  {name}: migration at {mig/1e6:.2f}s but NO post-migration samples")
        continue

    pinned = sum(1 for _, s, _ in post if s == INITIAL_RTT)
    sentinel = sum(1 for _, _, mr in post if mr == SENTINEL)
    span = (post[-1][0] - mig) / 1e6
    all_pinned = pinned == len(post)
    if all_pinned:
        pinned_reps += 1
    verdict = "PINNED" if all_pinned else f"NOT pinned ({pinned}/{len(post)})"
    print(f"  {name}: migration {mig/1e6:6.2f}s, {len(post):>5} post samples over "
          f"{span:5.1f}s -> srtt {verdict}; min_rtt sentinel {sentinel}/{len(post)}")
    if not all_pinned:
        others = sorted({s for _, s, _ in post if s != INITIAL_RTT})
        print(f"        non-333000 srtt values seen: {others[:6]}")

print("-" * 72)
print(f"RESULT: {pinned_reps}/{total_reps} reps have EVERY post-migration srtt "
      f"pinned at {INITIAL_RTT:,} us")
if pinned_reps == total_reps:
    print("  -> the original 5/5 claim is CORRECT; the fresh run's FAIL was an")
    print("     artefact of its crude 'last two-thirds' window, not a real")
    print("     disagreement.")
else:
    print("  -> the original claim does NOT hold; it must be corrected.")
print("=" * 72)
