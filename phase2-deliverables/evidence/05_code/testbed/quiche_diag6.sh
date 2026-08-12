#!/usr/bin/env bash
set -uo pipefail
cd /home/sivaa/pvseed || exit 1

SQLOG=$(find results/raw/quiche/diag_run1/qlog_client -name '*.sqlog' 2>/dev/null | head -1)
OUT=/home/sivaa/pvseed/results/raw/quiche/diag6b_out.txt

python3 - "$SQLOG" > "$OUT" 2>&1 <<'PYEOF'
import sys, json

path = sys.argv[1]
print("client qlog:", path)
with open(path, "rb") as f:
    raw = f.read()
chunks = raw.split(bytes([0x1e]))
records = []
skipped = 0
for c in chunks:
    if not c.strip():
        continue
    try:
        records.append(json.loads(c))
    except json.JSONDecodeError:
        skipped += 1
print("skipped truncated records:", skipped)
events = records[1:]

intervals = []
for e in events:
    if e.get("name") != "quic:packet_received":
        continue
    data = e.get("data") or {}
    for fr in (data.get("frames") or []):
        if fr.get("frame_type") != "stream":
            continue
        off = fr.get("offset")
        raw_info = fr.get("raw") or {}
        length = raw_info.get("length")
        if length is None:
            length = raw_info.get("payload_length")
        if off is None or length is None:
            print("WARNING: frame missing offset/length:", fr)
            continue
        intervals.append((off, off + length, fr.get("fin")))

print(f"total stream-frame intervals received: {len(intervals)}")
if not intervals:
    sys.exit(0)

intervals.sort()
merged = []
for s, e2, fin in intervals:
    if merged and s <= merged[-1][1]:
        merged[-1] = (merged[-1][0], max(merged[-1][1], e2), merged[-1][2] or fin)
    else:
        merged.append((s, e2, fin))

print(f"merged contiguous intervals: {len(merged)}")
for iv in merged[:20]:
    print(" ", iv)
if len(merged) > 20:
    print(f"  ... {len(merged)-20} more ...")
    for iv in merged[-10:]:
        print(" ", iv)

# find gaps
print("\n--- GAPS (space between consecutive merged intervals) ---")
for i in range(1, len(merged)):
    prev_end = merged[i-1][1]
    cur_start = merged[i][0]
    if cur_start > prev_end:
        print(f"  GAP: [{prev_end}, {cur_start})  size={cur_start-prev_end}")

first_start = merged[0][0]
if first_start > 0:
    print(f"  LEADING GAP: [0, {first_start}) size={first_start}")

last_end = merged[-1][1]
print(f"\nfinal contiguous coverage ends at: {last_end}")
print(f"file size is: 41943040")
print(f"final fin flag seen: {merged[-1][2]}")
PYEOF

cat "$OUT"
