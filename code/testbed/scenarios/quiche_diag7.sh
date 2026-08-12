#!/usr/bin/env bash
set -uo pipefail
cd /home/sivaa/pvseed || exit 1

SQLOG=$(find results/raw/quiche/diag_run1/qlog_server -name '*.sqlog' 2>/dev/null | head -1)
OUT=/home/sivaa/pvseed/results/raw/quiche/diag7_out.txt

python3 - "$SQLOG" > "$OUT" 2>&1 <<'PYEOF'
import sys, json

path = sys.argv[1]
print("server qlog:", path)
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
print("skipped truncated:", skipped)
events = records[1:]

print("packet_lost total:", sum(1 for e in events if e.get("name") == "quic:packet_lost"))

mus = [e for e in events if e.get("name") == "quic:recovery_metrics_updated"]
bif = [(e.get("time"), (e.get("data") or {}).get("bytes_in_flight")) for e in mus]
bif = [(t, b) for t, b in bif if b is not None]
print("bytes_in_flight samples:", len(bif))
# print one sample every ~1000
step = max(1, len(bif)//60)
for i in range(0, len(bif), step):
    print(f"  t={bif[i][0]:>10.1f}  bytes_in_flight={bif[i][1]:>10}")
print("LAST 10:")
for t, b in bif[-10:]:
    print(f"  t={t:>10.1f}  bytes_in_flight={b:>10}")

# also print max bytes_in_flight and when
mx = max(bif, key=lambda x: x[1])
print("MAX bytes_in_flight:", mx)

print("\ncongestion_state_updated:")
for e in events:
    if e.get("name") == "quic:congestion_state_updated":
        print(" ", e.get("time"), e.get("data"))
PYEOF
cat "$OUT"
