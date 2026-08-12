#!/usr/bin/env bash
set -uo pipefail
D=/home/sivaa/pvseed/results/raw/baseline/step_down/specreset/rep1/attempt1
SQ=$(ls "$D"/qlog_server/*.qlog | head -1)
echo "qlog: $SQ"
python3 - "$SQ" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    doc = json.load(f)
trace = doc["traces"][0]
fields = trace["event_fields"]
idx = {n: fields.index(n) for n in ("relative_time", "category", "event", "data")}
ti, ci, ei, di = idx["relative_time"], idx["category"], idx["event"], idx["data"]
rows = []
for ev in trace["events"]:
    t, cat, name, data = ev[ti], ev[ci], ev[ei], ev[di]
    if isinstance(data, dict) and name == "metrics_updated" and "cwnd" in data:
        rows.append((t, data.get("cwnd"), data.get("bytes_in_flight"),
                      data.get("smoothed_rtt"), data.get("min_rtt"), data.get("latest_rtt")))
print("t_us, cwnd, bif, smoothed_rtt, min_rtt, latest_rtt  (t=4.9s..8.5s)")
for t, cwnd, bif, srtt, mrtt, lrtt in rows:
    if 4_900_000 <= t <= 8_500_000:
        print(f"  t={t:>10}  cwnd={cwnd!s:>9}  bif={bif!s:>9}  srtt={srtt!s:>8}  min_rtt={mrtt!s:>8}  latest_rtt={lrtt!s:>8}")
PYEOF
