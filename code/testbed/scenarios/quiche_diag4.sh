#!/usr/bin/env bash
set -uo pipefail
cd /home/sivaa/pvseed || exit 1

SQLOG=$(find results/raw/quiche/migrate_demo/rep_1/qlog_server -name '*.sqlog' 2>/dev/null | head -1)
OUT=/home/sivaa/pvseed/results/raw/quiche/diag4_out.txt

python3 - "$SQLOG" > "$OUT" 2>&1 <<'PYEOF'
import sys, json
from collections import Counter

path = sys.argv[1]
print("server qlog:", path)
with open(path, "rb") as f:
    raw = f.read()
chunks = raw.split(bytes([0x1e]))
records = [json.loads(c) for c in chunks if c.strip()]
events = records[1:]

# Extract every STREAM frame carried in packet_sent events, with time and offset/length.
stream_frames = []
for e in events:
    if e.get("name") != "quic:packet_sent":
        continue
    t = e.get("time")
    data = e.get("data") or {}
    for fr in (data.get("frames") or []):
        if fr.get("frame_type") == "stream":
            stream_frames.append((t, fr.get("offset"), fr.get("length"), fr.get("fin")))

print("total STREAM frames sent:", len(stream_frames))
if stream_frames:
    print("first 5:", stream_frames[:5])
    print("last 10:", stream_frames[-10:])

    # bucket by 1-second windows, report max offset+length reached and count
    buckets = {}
    for t, off, ln, fin in stream_frames:
        if t is None or off is None:
            continue
        b = int(t // 1000)
        end = off + (ln or 0)
        cur = buckets.get(b, (0, 0))
        buckets[b] = (max(cur[0], end), cur[1] + 1)
    for b in sorted(buckets):
        print(f"  t=[{b*1000},{b*1000+1000}) max_end_offset={buckets[b][0]:>10} frames={buckets[b][1]}")

# Also: how many DISTINCT offsets were sent more than once (retransmission indicator)?
offset_counts = Counter()
for t, off, ln, fin in stream_frames:
    if off is not None:
        offset_counts[off] += 1
dupes = {k: v for k, v in offset_counts.items() if v > 1}
print(f"\ndistinct offsets sent more than once: {len(dupes)} (out of {len(offset_counts)} distinct offsets)")
# show a few of the most-repeated
top = sorted(dupes.items(), key=lambda kv: -kv[1])[:10]
print("most repeated offsets:", top)

print("\n--- packets_acked events (server side) ---")
pa = [e for e in events if e.get("name") == "quic:packets_acked"]
print("count:", len(pa))
for e in pa[:3]:
    print(" ", e.get("time"), e.get("data"))
for e in pa[-3:]:
    print(" ", e.get("time"), e.get("data"))
PYEOF

cat "$OUT"
