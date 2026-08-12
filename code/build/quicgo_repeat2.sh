#!/usr/bin/env bash
# Reproducibility check, corrected: the trial script hardcodes its output
# directory and does NOT emit metrics CSV (the qlog parser runs separately),
# so each repeat must be parsed and archived before the next run overwrites it.
set -uo pipefail
P=/home/sivaa/pvseed
TRIAL="$P/testbed/scenarios/quicgo_migrate_demo.sh"
DEF="$P/results/raw/quicgo/migrate_demo"
PARSER="$P/analysis/parse_qlog_quicgo.py"
BASE="$P/results/raw/quicgo/repeat"
N=${N:-3}

echo "=== parser interface ==="
python3 "$PARSER" --help 2>&1 | head -14

mkdir -p "$BASE"
for i in $(seq 1 "$N"); do
    echo
    echo "############ REPEAT $i / $N ############"
    OUT="$BASE/rep$i"; rm -rf "$OUT"; mkdir -p "$OUT"
    bash "$TRIAL" > "$OUT/run.log" 2>&1
    echo "  trial exit=$?"
    SQ=$(ls -S "$DEF"/qlog_server/*.sqlog 2>/dev/null | head -1)
    if [ -z "$SQ" ]; then echo "  NO SERVER QLOG"; continue; fi
    cp -f "$DEF/client_stdout.log" "$DEF/server_stdout.log" "$OUT/" 2>/dev/null
    python3 "$PARSER" --qlog "$SQ" --label arm=quicgo --label rep="$i" \
        --csv "$OUT/server_metrics.csv" > "$OUT/parse.log" 2>&1 \
      || python3 "$PARSER" "$SQ" > "$OUT/server_metrics.csv" 2>"$OUT/parse.log"
    if [ -s "$OUT/server_metrics.csv" ]; then
        echo "  parsed: $(( $(wc -l < "$OUT/server_metrics.csv") - 1 )) rows"
    else
        echo "  PARSE FAILED:"; head -5 "$OUT/parse.log"
    fi
    grep -o "MIGRATE_CUTOVER_CONFIRMED.*" "$OUT/client_stdout.log" 2>/dev/null | head -1
done

echo
echo "############ SUMMARY ############"
python3 - "$BASE" "$N" <<'PYEOF'
import csv, os, sys
base, n = sys.argv[1], int(sys.argv[2])
QG_IW = 32 * 1280
print(f"  {'rep':>4} {'peak pre':>11} {'post':>9} {'xIW':>6} {'1st srtt':>10}  verdict")
ok = 0
for i in range(1, n+1):
    p = os.path.join(base, f"rep{i}", "server_metrics.csv")
    if not os.path.exists(p) or os.path.getsize(p) == 0:
        print(f"  {i:>4}  (no data)"); continue
    rows = []
    with open(p) as f:
        for r in csv.DictReader(f):
            d = {}
            for k in ("time_us","cwnd","smoothed_rtt"):
                v = r.get(k); d[k] = float(v) if v not in ("", None) else None
            if d.get("time_us") is not None: rows.append(d)
    rows.sort(key=lambda r: r["time_us"])
    cw = [(r["time_us"], r["cwnd"]) for r in rows if r["cwnd"]]
    sr = [r for r in rows if r["smoothed_rtt"]]
    if not cw or len(sr) < 3:
        print(f"  {i:>4}  (insufficient samples)"); continue
    hit = next(((t, c) for t, c in cw if t > 4.0e6 and abs(c - QG_IW) < 1), None)
    pre = [c for t, c in cw if t > 4.0e6 and (hit is None or t < hit[0])]
    gaps = [(sr[j+1]["time_us"]-sr[j]["time_us"], j) for j in range(len(sr)-1)]
    _, gi = max(gaps)
    fa = sr[gi+1]["smoothed_rtt"]/1000.0
    if hit:
        ok += 1
        print(f"  {i:>4} {max(pre) if pre else 0:11,.0f} {hit[1]:9,.0f} {hit[1]/QG_IW:6.2f} {fa:8.1f}ms  RESET CONFIRMED")
    else:
        mn = min(c for t, c in cw if t > 4.0e6)
        print(f"  {i:>4} {max(pre) if pre else 0:11,.0f} {mn:9,.0f} {mn/QG_IW:6.2f} {fa:8.1f}ms  no exact-IW sample")
print(f"\n  {ok}/{n} repeats show cwnd returning to exactly {QG_IW:,} B at migration")
print("  path B configured delay = 40 ms")
PYEOF
echo
echo "DONE"
