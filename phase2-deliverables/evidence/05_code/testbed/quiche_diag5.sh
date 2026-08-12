#!/usr/bin/env bash
set -uo pipefail
cd /home/sivaa/pvseed || exit 1

SQLOG=$(find results/raw/quiche/diag_run1/qlog_client -name '*.sqlog' 2>/dev/null | head -1)
OUT=/home/sivaa/pvseed/results/raw/quiche/diag5_out.txt

python3 - "$SQLOG" > "$OUT" 2>&1 <<'PYEOF'
import sys, json
from collections import Counter

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
        skipped += 1  # tolerate a truncated trailing record (process was exit()'d, not cleanly dropped)
print(f"skipped {skipped} unparseable (likely truncated) trailing record(s)")
events = records[1:]

# Extract every STREAM frame the CLIENT'S TRANSPORT received, regardless of
# whether it was ever promoted to "application".
stream_frames_recv = []
for e in events:
    if e.get("name") != "quic:packet_received":
        continue
    t = e.get("time")
    data = e.get("data") or {}
    for fr in (data.get("frames") or []):
        if fr.get("frame_type") == "stream":
            stream_frames_recv.append((t, fr.get("offset"), fr.get("length"), fr.get("fin")))

print("total STREAM frames RECEIVED (transport level):", len(stream_frames_recv))
if stream_frames_recv:
    print("first 3:", stream_frames_recv[:3])
    print("last 15:", stream_frames_recv[-15:])
    maxoff = max((o or 0) + (l or 0) for t, o, l, fin in stream_frames_recv)
    print("max end offset ever received at transport level:", maxoff)

    # bucket by 1s
    buckets = {}
    for t, off, ln, fin in stream_frames_recv:
        if t is None or off is None:
            continue
        b = int(t // 1000)
        end = off + (ln or 0)
        cur = buckets.get(b, (0, 0))
        buckets[b] = (max(cur[0], end), cur[1] + 1)
    for b in sorted(buckets):
        print(f"  t=[{b*1000},{b*1000+1000}) max_end_offset={buckets[b][0]:>10} frames={buckets[b][1]}")

# Also check ACK frames the client SENT (packet_sent) to see if it's acking
# a range that implies it thinks it has data beyond the stall point (would
# indicate an ACK-generation bug, acking data it never actually delivered).
print("\n--- gaps: sorted unique offsets, look for a hole ---")
offs = sorted(set(o for t, o, l, fin in stream_frames_recv if o is not None))
# compute coverage as intervals
intervals = []
for t, o, l, fin in stream_frames_recv:
    if o is None:
        continue
    intervals.append((o, o + (l or 0)))
intervals.sort()
merged = []
for s, e2 in intervals:
    if merged and s <= merged[-1][1]:
        merged[-1] = (merged[-1][0], max(merged[-1][1], e2))
    else:
        merged.append((s, e2))
print(f"merged contiguous-received intervals (count={len(merged)}):")
for s, e2 in merged[:20]:
    print(f"  [{s}, {e2})  size={e2-s}")
if len(merged) > 20:
    print(f"  ... and {len(merged)-20} more intervals")
    print("last 5 intervals:", merged[-5:])
PYEOF

cat "$OUT"
