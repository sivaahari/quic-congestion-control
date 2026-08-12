#!/usr/bin/env bash
# Potentially the most interesting msquic observation: after migration the
# SERVER's RTT estimator appears never to recover -- srtt stuck at the 333 ms
# initial default and min_rtt stuck at the UINT32_MAX sentinel, for the whole
# remainder of the connection. Verify across all reps and over time, not just
# at the tail.
set -uo pipefail
R=/home/sivaa/pvseed/results/raw/msquic/migrate_demo

python3 - "$R" <<'PYEOF'
import csv, glob, os, sys
R = sys.argv[1]
SENTINEL = 4294967295
for d in sorted(glob.glob(os.path.join(R, "rep_*"))):
    f = os.path.join(d, "server_metrics.csv")
    if not os.path.exists(f):
        continue
    rows = []
    with open(f) as fh:
        for r in csv.DictReader(fh):
            def g(k):
                v = r.get(k)
                try: return float(v) if v not in ("", None) else None
                except ValueError: return None
            t = g("time_us")
            if t is not None:
                rows.append((t, g("cwnd"), g("smoothed_rtt"), g("min_rtt")))
    rows.sort()
    if not rows:
        continue
    name = os.path.basename(d)

    # migration = first sample at the initial window after t=4s
    mig = next((t for t, c, s, m in rows if c and abs(c - 12200) < 1 and t > 4.0e6), None)
    post = [(t, s, m) for t, c, s, m in rows if mig and t > mig]
    if not post:
        print(f"  {name}: no post-migration samples"); continue

    srtts = [s for _, s, _ in post if s is not None]
    mins  = [m for _, _, m in post if m is not None]
    stuck_srtt = all(abs(s - 333000) < 1 for s in srtts) if srtts else None
    n_sentinel = sum(1 for m in mins if m == SENTINEL)
    recovered = next(((t, m) for t, _, m in post if m is not None and m != SENTINEL), None)

    last_t = post[-1][0]
    print(f"  {name}: migration at t={mig/1e6:6.2f}s, trace ends t={last_t/1e6:6.2f}s "
          f"({(last_t-mig)/1e6:5.1f}s after)")
    print(f"      post-migration srtt samples : {len(srtts)}, "
          f"{'ALL still 333,000 us (never updated)' if stuck_srtt else 'some updated'}")
    if srtts and not stuck_srtt:
        print(f"      srtt range after: {min(srtts):,.0f} .. {max(srtts):,.0f} us")
    print(f"      min_rtt at sentinel: {n_sentinel}/{len(mins)} samples"
          + (f"; first real value {recovered[1]:,.0f} us at t={recovered[0]/1e6:.2f}s"
             if recovered else "; NEVER recovered a real value"))
PYEOF

echo
echo "=== does the client (which did NOT reset) keep a sane RTT? ==="
python3 - "$R" <<'PYEOF'
import csv, glob, os, sys
R = sys.argv[1]
for d in sorted(glob.glob(os.path.join(R, "rep_*"))):
    f = os.path.join(d, "client_metrics.csv")
    if not os.path.exists(f): continue
    vals = []
    with open(f) as fh:
        for r in csv.DictReader(fh):
            try:
                t = float(r.get("time_us") or 0)
                s = r.get("smoothed_rtt"); m = r.get("min_rtt")
                vals.append((t, float(s) if s else None, float(m) if m else None))
            except ValueError:
                pass
    vals.sort()
    tail = [v for v in vals if v[1]][-1:]
    if tail:
        t, s, m = tail[0]
        print(f"  {os.path.basename(d)}: final client srtt={s:,.0f} us  min_rtt={m if m is None else format(m, ',.0f')} us")
PYEOF
echo
echo "  Path A true delay 20 ms, path B true delay 40 ms."
echo "  A server stuck at 333,000 us is pacing on an RTT ~8x the real one."
echo DONE
