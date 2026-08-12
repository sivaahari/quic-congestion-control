#!/usr/bin/env bash
set -uo pipefail
cd /home/sivaa/pvseed || exit 1

SQLOG=$(find results/raw/quiche/migrate_demo/rep_1/qlog_server -name '*.sqlog' 2>/dev/null | head -1)
echo "server qlog: $SQLOG"

python3 - "$SQLOG" <<'PYEOF'
import sys, json
from collections import Counter

path = sys.argv[1]
with open(path, "rb") as f:
    raw = f.read()
chunks = raw.split(bytes([0x1e]))
records = [json.loads(c) for c in chunks if c.strip()]
header = records[0]
events = records[1:]
print("total events:", len(events))

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

# cwnd/bytes_in_flight trend after migration
print("\n--- recovery_metrics_updated t=4900..7000 ---")
for e in events:
    if e.get("name") == "quic:recovery_metrics_updated":
        t = e.get("time")
        if t is not None and 4900 <= t <= 7000:
            print(f"  t={t} data={e.get('data')}")

print("\n--- recovery_metrics_updated sampled every 2000 events after migration window ---")
mus = [e for e in events if e.get("name") == "quic:recovery_metrics_updated" and (e.get("time") or 0) > 5000]
for i in range(0, len(mus), max(1, len(mus)//30)):
    e = mus[i]
    print(f"  t={e.get('time')} data={e.get('data')}")

print("\n--- packet_lost count before vs after t=5000 ---")
before = sum(1 for e in events if e.get("name")=="quic:packet_lost" and (e.get("time") or 0) <= 5000)
after = sum(1 for e in events if e.get("name")=="quic:packet_lost" and (e.get("time") or 0) > 5000)
print(f"  before: {before}  after: {after}")

print("\n--- packet_lost trigger breakdown ---")
trig = Counter()
for e in events:
    if e.get("name") == "quic:packet_lost":
        trig[(e.get("data") or {}).get("trigger")] += 1
print(dict(trig))

print("\n--- stream_data_moved events near migration (t=4900..5500) ---")
n=0
for e in events:
    if e.get("name") == "quic:stream_data_moved":
        t = e.get("time")
        if t is not None and 4900 <= t <= 5500:
            print(f"  t={t} data={e.get('data')}")
            n+=1
            if n>15: break

print("\n--- LAST stream_data_moved event (to see final offset reached) ---")
sdm = [e for e in events if e.get("name") == "quic:stream_data_moved"]
print("count:", len(sdm))
if sdm:
    for e in sdm[-5:]:
        print(f"  t={e.get('time')} data={e.get('data')}")

print("\n--- congestion_state_updated events ---")
for e in events:
    if e.get("name") == "quic:congestion_state_updated":
        print(f"  t={e.get('time')} data={e.get('data')}")

print("\n--- connection_closed event ---")
for e in events:
    if e.get("name") == "quic:connection_closed":
        print(f"  t={e.get('time')} data={e.get('data')}")
PYEOF
