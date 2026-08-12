#!/usr/bin/env bash
set -uo pipefail
cd /home/sivaa/pvseed || exit 1

SQLOG=$(find results/raw/quiche/migrate_demo/rep_1/qlog_client -name '*.sqlog' 2>/dev/null | head -1)
OUT=/home/sivaa/pvseed/results/raw/quiche/diag3_out.txt

python3 - "$SQLOG" > "$OUT" 2>&1 <<'PYEOF'
import sys, json
from collections import Counter

path = sys.argv[1]
print("client qlog:", path)
with open(path, "rb") as f:
    raw = f.read()
chunks = raw.split(bytes([0x1e]))
records = [json.loads(c) for c in chunks if c.strip()]
events = records[1:]
print("total events:", len(events))

name_counts = Counter(e.get("name") for e in events)
for k, v in sorted(name_counts.items(), key=lambda x: -x[1]):
    print(f"  {k}: {v}")

sdm = [e for e in events if e.get("name") == "quic:stream_data_moved"]
print("\nstream_data_moved count:", len(sdm))
to_counts = Counter()
for e in sdm:
    d = e.get("data") or {}
    to_counts[(d.get("from"), d.get("to"))] += 1
print("from->to breakdown:", dict(to_counts))

# max offset seen for each (from,to) pair
max_off = {}
for e in sdm:
    d = e.get("data") or {}
    key = (d.get("from"), d.get("to"))
    off = d.get("offset") or 0
    ln = (d.get("raw") or {}).get("length") or 0
    end = off + ln
    if key not in max_off or end > max_off[key]:
        max_off[key] = end
print("max end-offset per (from,to):", max_off)

print("\nlast 10 stream_data_moved events:")
for e in sdm[-10:]:
    print(" ", e.get("time"), e.get("data"))

print("\nfirst 5 stream_data_moved events with to=application:")
n=0
for e in sdm:
    d = e.get("data") or {}
    if d.get("to") == "application":
        print(" ", e.get("time"), d)
        n+=1
        if n>=5: break

print("\nlast 5 stream_data_moved events with to=application:")
appl = [e for e in sdm if (e.get("data") or {}).get("to") == "application"]
print("count application:", len(appl))
for e in appl[-5:]:
    print(" ", e.get("time"), e.get("data"))

print("\npacket_lost on client:", sum(1 for e in events if e.get("name")=="quic:packet_lost"))
print("connection_closed:", [e for e in events if e.get("name")=="quic:connection_closed"])

print("\nrecovery_metrics_updated last 5:")
mus = [e for e in events if e.get("name") == "quic:recovery_metrics_updated"]
for e in mus[-5:]:
    print(" ", e.get("time"), e.get("data"))
PYEOF

cat "$OUT"
