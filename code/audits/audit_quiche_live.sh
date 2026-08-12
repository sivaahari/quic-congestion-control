#!/usr/bin/env bash
# quiche audit part 4 -- the live data.
#
# The rep summaries report "cwnd BEFORE: n/a", meaning no pre-migration cwnd
# sample was found. That must be explained before the cwnd numbers are trusted:
# quiche emits PER-PATH metrics, so a parser that ignores the path id can mix
# two different controllers into one series.
set -uo pipefail
M=/home/sivaa/pvseed/results/raw/quiche/migrate_demo

echo "############ does quiche's qlog tag metrics by PATH? ############"
SQ=$(ls -S "$M"/rep_1/qlog_server/*.sqlog 2>/dev/null | head -1)
echo "  $SQ"
python3 - "$SQ" <<'PYEOF'
import json, sys
p = sys.argv[1]
seen_keys, n_metrics, path_tagged = set(), 0, 0
samples = []
with open(p, "rb") as f:
    for raw in f:
        raw = raw.strip().lstrip(b"\x1e")
        if not raw:
            continue
        try:
            ev = json.loads(raw)
        except Exception:
            continue
        name = ev.get("name") or ev.get("event")
        if name and "metrics_updated" in str(name):
            n_metrics += 1
            d = ev.get("data", {})
            seen_keys.update(d.keys())
            if any(k in ev for k in ("path", "path_id", "pid")) or "path_id" in d:
                path_tagged += 1
            if n_metrics <= 3:
                samples.append({k: ev.get(k) for k in ("time","name","path","path_id")} | {"data_keys": list(d)[:8]})
print(f"  metrics_updated events: {n_metrics}")
print(f"  of which carry a path id: {path_tagged}")
print(f"  union of data keys: {sorted(seen_keys)}")
for s in samples:
    print("   sample:", s)
PYEOF

echo
echo "############ cwnd trajectory across the migration (rep_1) ############"
python3 - "$M/rep_1/server_metrics.csv" <<'PYEOF'
import csv, sys
rows = []
with open(sys.argv[1]) as f:
    for r in csv.DictReader(f):
        d = {}
        for k in ("time_us","cwnd","smoothed_rtt","min_rtt"):
            v = r.get(k); d[k] = float(v) if v not in ("", None) else None
        if d["time_us"] is not None: rows.append(d)
rows.sort(key=lambda r: r["time_us"])
cw = [(r["time_us"], r["cwnd"]) for r in rows if r["cwnd"]]
print(f"  total rows {len(rows)}, of which {len(cw)} carry cwnd")
if cw:
    print(f"  first cwnd sample at t={cw[0][0]/1e6:.3f}s = {cw[0][1]:,.0f} B")
    print(f"  last  cwnd sample at t={cw[-1][0]/1e6:.3f}s = {cw[-1][1]:,.0f} B")
    print("\n  cwnd samples between t=4.5s and t=5.6s (migration ~5.02s):")
    print(f"    {'t (s)':>9} {'cwnd (B)':>12}")
    win = [(t,c) for t,c in cw if 4.5e6 <= t <= 5.6e6]
    step = max(1, len(win)//28)
    for t,c in win[::step]:
        print(f"    {t/1e6:9.4f} {c:12,.0f}")
    pre  = [c for t,c in cw if t < 5.0e6]
    post = [(t,c) for t,c in cw if 5.0e6 <= t <= 5.3e6]
    if pre:  print(f"\n  max cwnd BEFORE 5.0s : {max(pre):,.0f} B")
    if post: print(f"  min cwnd 5.0-5.3s    : {min(c for _,c in post):,.0f} B")
PYEOF

echo
echo "############ per-path min_rtt from path_stats (the Q3 cross-check) ############"
for i in 1 2 3 4 5; do
    echo "--- rep_$i ---"
    grep -o "local_addr=10\.0\.9\.1:4433 peer_addr=10\.0\.[13]\.1:[0-9]* .*min_rtt=Some([^)]*)" \
        "$M/rep_$i/server_stderr.log" 2>/dev/null \
      | sed -E 's/.*peer_addr=(10\.0\.[13]\.1):[0-9]+.*min_rtt=Some\(([^)]*)\).*/    peer \1  min_rtt=\2/' \
      || echo "    (no path_stats)"
done
echo
echo "  path A configured delay = 20 ms (peer 10.0.1.1)"
echo "  path B configured delay = 40 ms (peer 10.0.3.1)"
echo "  If each path's min_rtt matches its own configured delay, per-path"
echo "  attribution is working -> Q3 corroborated at runtime."
echo DONE
