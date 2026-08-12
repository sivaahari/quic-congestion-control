#!/usr/bin/env bash
set -uo pipefail
cd /home/sivaa/pvseed || exit 1

SQLOG=$(find results/raw/quiche/migrate_demo/rep_1/qlog_server -name '*.sqlog' 2>/dev/null | head -1)
echo "server qlog: $SQLOG"

python3 - "$SQLOG" <<'PYEOF'
import sys, json

path = sys.argv[1]
with open(path, "rb") as f:
    raw = f.read()

chunks = raw.split(bytes([0x1e]))
records = [json.loads(c) for c in chunks if c.strip()]
header = records[0]
events = records[1:]
print("total events:", len(events))

from collections import Counter
name_counts = Counter(e.get("name") for e in events)
for k, v in sorted(name_counts.items(), key=lambda x: -x[1]):
    print(f"  {k}: {v}")

print("\n--- blocked-frame scan ---")
blocked = 0
for e in events:
    data = e.get("data") or {}
    for fr in (data.get("frames") or []):
        ft = fr.get("frame_type", "")
        if "blocked" in ft:
            blocked += 1
            if blocked <= 10:
                print(f"  t={e.get('time')} name={e.get('name')} frame={fr}")
print("total blocked-type frames:", blocked)

print("\n--- recovery_metrics_updated around t=5000..6500 (ms) ---")
for e in events:
    if e.get("name") == "quic:recovery_metrics_updated":
        t = e.get("time")
        if t is not None and 4800 <= t <= 6500:
            print(f"  t={t} data={e.get('data')}")

print("\n--- packet_lost sample (first 5) ---")
n = 0
for e in events:
    if e.get("name") == "quic:packet_lost":
        print(f"  t={e.get('time')} data={e.get('data')}")
        n += 1
        if n >= 5:
            break

print("\n--- last 5 recovery_metrics_updated events overall ---")
mus = [e for e in events if e.get("name") == "quic:recovery_metrics_updated"]
for e in mus[-5:]:
    print(f"  t={e.get('time')} data={e.get('data')}")

print("\n--- last 10 events of ANY type (to see what the trace ends with) ---")
for e in events[-10:]:
    print(f"  t={e.get('time')} name={e.get('name')}")
PYEOF
