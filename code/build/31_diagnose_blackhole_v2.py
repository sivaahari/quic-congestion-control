import json, glob

qlog_server = glob.glob("/home/sivaa/pvseed/results/raw/baseline/step_down/specreset/rep1/attempt1/qlog_server/*.qlog")[0]

d = json.load(open(qlog_server))
tr = d["traces"][0]
f = tr["event_fields"]
ti, ci, ei, di = (f.index(x) for x in ("relative_time", "category", "event", "data"))

events = tr["events"]
path_ev_t = []
for ev in events:
    t, cat, name, data = ev[ti], ev[ci], ev[ei], ev[di]
    if isinstance(data, dict) and name in ("packet_sent", "packet_received"):
        for fr in data.get("frames") or []:
            if fr.get("frame_type", "").startswith("path_"):
                path_ev_t.append(t)
t1 = max(path_ev_t)
print(f"t1={t1}")
print(f"Dumping ALL server-side events from t1-20ms to t1+3000ms, full detail:\n")

for ev in events:
    t, cat, name, data = ev[ti], ev[ci], ev[ei], ev[di]
    if not (t1 - 20_000 <= t <= t1 + 3_000_000):
        continue
    if name == "metrics_updated":
        print(f"t={t:>10} [metrics_updated] cwnd={data.get('cwnd')} srtt={data.get('smoothed_rtt')} "
              f"bytes_in_flight={data.get('bytes_in_flight')} min_rtt={data.get('min_rtt')} "
              f"pacing_rate={data.get('pacing_rate')} ssthresh={data.get('ssthresh')}")
    elif name == "packet_lost":
        print(f"t={t:>10} [packet_lost] trigger={data.get('trigger')} pn={data.get('header',{}).get('packet_number')}")
    elif name == "packet_sent":
        frames = [fr.get('frame_type') for fr in (data.get('frames') or [])]
        pn = data.get('header', {}).get('packet_number')
        print(f"t={t:>10} [packet_sent] pn={pn} frames={frames}")
    elif name == "packet_received":
        frames = [fr.get('frame_type') for fr in (data.get('frames') or [])]
        pn = data.get('header', {}).get('packet_number')
        print(f"t={t:>10} [packet_received] pn={pn} frames={frames}")
    elif name == "message" or cat == "info":
        print(f"t={t:>10} [info/{name}] {json.dumps(data)}")
    elif "timer" in name.lower() or "loss" in name.lower() or "recovery" in cat.lower():
        print(f"t={t:>10} [{cat}/{name}] {json.dumps(data)[:300]}")
    else:
        pass  # skip datagram_sent/received noise

print("\nDONE")
