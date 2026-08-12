#!/usr/bin/env bash
# msquic audit part 3 -- discriminator constants and live data verification.
set -uo pipefail
M=/home/sivaa/pvseed/msquic
R=/home/sivaa/pvseed/results/raw/msquic/migrate_demo

echo "=============================================================="
echo "1. Discriminator constants (from source, not asserted)"
echo "=============================================================="
grep -rn "define QUIC_INITIAL_WINDOW_PACKETS\|define QUIC_PERSISTENT_CONGESTION_WINDOW_PACKETS\|define TEN_TIMES_BETA_CUBIC\|define QUIC_INITIAL_RTT\|define QUIC_DEFAULT_PATH_MTU\|InitialWindowPackets" \
    "$M/src/core/"*.h "$M/src/inc/"*.h 2>/dev/null | head -14
echo
echo "--- the 1220 payload figure ---"
grep -rn "1220\|QUIC_MIN_INITIAL_LENGTH\|DEFAULT_QUIC_MTU\|QUIC_DPLPMUTD_MIN_MTU" \
    "$M/src/inc/quic_datapath.h" "$M/src/core/mtu_discovery.h" 2>/dev/null | head -8

echo
echo "=============================================================="
echo "2. Which reps exist, and did they complete?"
echo "=============================================================="
ls -d "$R"/rep_* 2>/dev/null | sort
for d in "$R"/rep_*; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    dl=$(stat -c%s "$d/downloaded.bin" 2>/dev/null || echo 0)
    printf "  %-8s downloaded=%12s B  %s\n" "$n" "$dl" \
        "$([ "$dl" = "41943040" ] && echo OK || echo INCOMPLETE)"
done

echo
echo "=============================================================="
echo "3. SERVER cwnd across the migration (the sender for a download)"
echo "=============================================================="
python3 - "$R" <<'PYEOF'
import csv, glob, os, sys
R = sys.argv[1]
IW = 12200          # claim: 10 x 1220
print(f"  {'rep':>6} {'cwnd before':>13} {'cwnd after':>12} {'xIW':>6} {'srtt after':>12} {'min_rtt after':>14}")
for d in sorted(glob.glob(os.path.join(R, "rep_*"))):
    f = os.path.join(d, "server_metrics.csv")
    if not os.path.exists(f):
        print(f"  {os.path.basename(d):>6}  (no server_metrics.csv)"); continue
    rows = []
    with open(f) as fh:
        for r in csv.DictReader(fh):
            try:
                t = float(r.get("time_us") or 0)
            except ValueError:
                continue
            def g(k):
                v = r.get(k)
                try: return float(v) if v not in ("", None) else None
                except ValueError: return None
            rows.append((t, g("cwnd"), g("smoothed_rtt"), g("min_rtt")))
    rows.sort()
    cw = [(t,c,s,m) for t,c,s,m in rows if c]
    if not cw:
        print(f"  {os.path.basename(d):>6}  (no cwnd samples)"); continue
    # the reset is the first sample at/near the initial window after t=4s
    hit = next(((t,c,s,m) for t,c,s,m in cw if t > 4.0e6 and abs(c-IW) < 1), None)
    pre = [c for t,c,s,m in cw if t > 3.0e6 and (hit is None or t < hit[0])]
    if hit:
        t,c,s,m = hit
        ss = f"{s:,.0f}" if s else "-"
        mm = f"{m:,.0f}" if m else "-"
        print(f"  {os.path.basename(d):>6} {max(pre) if pre else 0:13,.0f} {c:12,.0f} {c/IW:6.2f} {ss:>12} {mm:>14}")
    else:
        mn = min(c for t,c,s,m in cw if t > 4.0e6) if any(t>4.0e6 for t,c,s,m in cw) else 0
        print(f"  {os.path.basename(d):>6} {max(pre) if pre else 0:13,.0f} {mn:12,.0f} {mn/IW:6.2f}  NO EXACT-IW SAMPLE")
print()
print(f"  claimed initial window = 10 x 1220 = {IW:,} B")
print( "  cubic loss backoff would give ~0.7 x pre-migration cwnd")
print( "  persistent-congestion floor = 2 x 1220 = 2,440 B")
PYEOF

echo
echo "=============================================================="
echo "4. CLIENT cwnd across ITS OWN migration (claim: flat = no reset)"
echo "=============================================================="
python3 - "$R" <<'PYEOF'
import csv, glob, os, sys
R = sys.argv[1]
for d in sorted(glob.glob(os.path.join(R, "rep_*"))):
    f = os.path.join(d, "client_metrics.csv")
    if not os.path.exists(f):
        continue
    rows = []
    with open(f) as fh:
        for r in csv.DictReader(fh):
            try: t = float(r.get("time_us") or 0)
            except ValueError: continue
            v = r.get("cwnd")
            try: c = float(v) if v not in ("", None) else None
            except ValueError: c = None
            if c: rows.append((t, c))
    rows.sort()
    if not rows: continue
    pre  = [c for t,c in rows if 3.0e6 < t < 5.0e6]
    post = [c for t,c in rows if 5.0e6 <= t < 6.5e6]
    print(f"  {os.path.basename(d):>6}  before={max(pre) if pre else 0:>10,.0f} B   "
          f"after(min)={min(post) if post else 0:>10,.0f} B   "
          f"{'FLAT - no reset' if pre and post and min(post) > 0.5*max(pre) else 'dropped'}")
PYEOF

echo
echo "=============================================================="
echo "5. Server log: did the reset branch actually fire? (rebind=0)"
echo "=============================================================="
for d in "$R"/rep_*; do
    [ -d "$d" ] || continue
    hit=$(grep -o "Path\[[0-9]*\] Set active (rebind=[01])" "$d"/server*.log 2>/dev/null | head -2 | tr '\n' ' ')
    printf "  %-8s %s\n" "$(basename "$d")" "${hit:-none found}"
done
echo "  rebind=0 means UdpPortChangeOnly was FALSE -> the reset branch ran."
echo DONE
