import json, glob

def analyze(qlog, label):
    d = json.load(open(qlog))
    tr = d["traces"][0]
    f = tr["event_fields"]
    ti, ci, ei, di = (f.index(x) for x in ("relative_time","category","event","data"))
    metrics = []
    path_ev = []
    for ev in tr["events"]:
        t, cat, name, data = ev[ti], ev[ci], ev[ei], ev[di]
        if not isinstance(data, dict):
            continue
        if name == "metrics_updated" and "cwnd" in data:
            metrics.append((t, data.get("cwnd"), data.get("smoothed_rtt")))
        elif name in ("packet_sent","packet_received"):
            for fr in data.get("frames") or []:
                if fr.get("frame_type","").startswith("path_"):
                    path_ev.append(t)
    if not path_ev or not metrics:
        print(f"[{label}] insufficient data")
        return
    t1 = max(path_ev)
    last_metric_t = metrics[-1][0]
    last_event_t = max(ev[ti] for ev in tr["events"])
    # cwnd values in first 500ms after t1
    early = [m for m in metrics if t1 <= m[0] <= t1 + 500_000]
    max_cwnd_500ms = max((m[1] for m in early if m[1] is not None), default=None)
    print(f"[{label}] t1={t1}  last_metrics_sample_t={last_metric_t} (delta={last_metric_t-t1})  "
          f"last_trace_event_t={last_event_t} (delta={last_event_t-t1})  "
          f"n_metrics_total={len(metrics)}  max_cwnd_within_500ms_of_t1={max_cwnd_500ms}")

base_v1 = "/home/sivaa/pvseed/results/raw/baseline_v1_contaminated/step_down/specreset"
for rep in range(1,6):
    g = glob.glob(f"{base_v1}/rep{rep}/final/qlog_server/*.qlog") or glob.glob(f"{base_v1}/rep{rep}/attempt*/qlog_server/*.qlog")
    if g:
        analyze(max(g, key=lambda p: __import__("os").path.getsize(p)), f"v1 rep{rep}")
    else:
        print(f"[v1 rep{rep}] no qlog found")
