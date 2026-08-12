#!/usr/bin/env bash
# Chase the discrepancy: downloaded.bin is 0 bytes in every rep, yet the report
# claimed content-verified 41,943,040-byte transfers in 4/5.
set -uo pipefail
R=/home/sivaa/pvseed/results/raw/msquic/migrate_demo

echo "=== rep_status.txt ==="
cat "$R/rep_status.txt" 2>/dev/null || echo "  (missing/empty)"

echo
echo "=== full contents of rep_1 ==="
ls -la "$R/rep_1/" 2>/dev/null

echo
echo "=== any large files anywhere under migrate_demo? ==="
find "$R" -type f -size +1M -printf '%-72p %12s B\n' 2>/dev/null | head -12

echo
echo "=== client log: completion / byte-count evidence (rep_1) ==="
CL=$(ls "$R"/rep_1/client*.log 2>/dev/null | head -1)
echo "  file: ${CL:-none}"
[ -n "$CL" ] && grep -iE "recv|receiv|bytes|complete|download|verif|SHUTDOWN|FIN" "$CL" 2>/dev/null | tail -12

echo
echo "=== server log: completion evidence (rep_1) ==="
SL=$(ls "$R"/rep_1/server*.log 2>/dev/null | head -1)
echo "  file: ${SL:-none}"
[ -n "$SL" ] && grep -iE "sent|bytes|complete|SHUTDOWN|FIN|DONE" "$SL" 2>/dev/null | tail -10

echo
echo "=== per-rep: does any artefact prove the transfer size? ==="
for d in "$R"/rep_*; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    dl=$(stat -c%s "$d/downloaded.bin" 2>/dev/null || echo "absent")
    rows=$(wc -l < "$d/server_metrics.csv" 2>/dev/null || echo 0)
    span=$(python3 - "$d/server_metrics.csv" <<'PY' 2>/dev/null || echo "?"
import csv,sys
ts=[]
try:
    for r in csv.DictReader(open(sys.argv[1])):
        v=r.get("time_us")
        if v: ts.append(float(v))
except Exception: pass
print(f"{(max(ts)-min(ts))/1e6:.1f}s" if ts else "?")
PY
)
    printf "  %-8s downloaded.bin=%-10s metrics_rows=%-8s trace_span=%s\n" "$n" "$dl" "$rows" "$span"
done
echo
echo "  A multi-second trace with cwnd reaching ~1.48 MB proves data DID flow."
echo "  The question is only whether the received file was retained on disk."
echo DONE
