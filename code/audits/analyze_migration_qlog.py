#!/usr/bin/env python3
"""Analyze a picoquic qlog (draft-00 style) to locate a connection migration
and report congestion-window / RTT behavior around it.

Usage: analyze_migration_qlog.py <qlog_file> [label]
"""
import json
import sys

def load(path):
    with open(path) as f:
        doc = json.load(f)
    trace = doc["traces"][0]
    return trace

def main():
    path = sys.argv[1]
    label = sys.argv[2] if len(sys.argv) > 2 else path
    trace = load(path)
    events = trace["events"]
    vp = trace.get("vantage_point", {})
    print(f"=== {label} ===")
    print(f"vantage_point: {vp}")
    print(f"total events: {len(events)}")

    # 1. Find path_challenge / path_response frames, with direction (sent/received)
    #    and any datagram addr_to/addr_from around them.
    challenge_events = []
    response_events = []
    for ev in events:
        rel_time, category, name, data = ev[0], ev[1], ev[2], ev[3]
        if not isinstance(data, dict):
            continue
        for fr in data.get("frames", []):
            ft = fr.get("frame_type", "")
            if ft == "path_challenge":
                challenge_events.append((rel_time, name, fr))
            elif ft == "path_response":
                response_events.append((rel_time, name, fr))

    print(f"\npath_challenge frames ({len(challenge_events)}):")
    for t, name, fr in challenge_events:
        print(f"  t={t:>10} us  {name:16s} {fr}")
    print(f"\npath_response frames ({len(response_events)}):")
    for t, name, fr in response_events:
        print(f"  t={t:>10} us  {name:16s} {fr}")

    # 2. Find any qlog events that mention addresses (datagram_sent/received have
    #    addr_to; look for the FIRST datagram sent/received involving a NEW ip
    #    that differs from the initial one).
    addr_seen = []
    first_addr = None
    switch_time = None
    for ev in events:
        rel_time, category, name, data = ev[0], ev[1], ev[2], ev[3]
        if not isinstance(data, dict):
            continue
        addr = data.get("addr_to") or data.get("addr_from")
        if addr and "ip_v4" in addr:
            ip = addr["ip_v4"]
            if first_addr is None:
                first_addr = ip
            if ip != first_addr and switch_time is None:
                switch_time = rel_time
                print(f"\nFIRST DATAGRAM WITH DIFFERENT ADDRESS: t={rel_time} us, {name}, addr={addr} (initial was {first_addr})")

    # 3. App-message log lines (picoquic_log_app_message), often include
    #    human-readable migration confirmations.
    print("\napp 'message' events containing 'migrat' or 'path':")
    for ev in events:
        rel_time, category, name, data = ev[0], ev[1], ev[2], ev[3]
        if name == "message" and isinstance(data, dict):
            msg = data.get("message", "")
            if "migrat" in msg.lower() or "path" in msg.lower():
                print(f"  t={rel_time:>10} us  {msg}")

    # 4. metrics_updated series -- print full series compactly, then a
    #    zoomed window around the challenge time (if found).
    metrics = []
    for ev in events:
        rel_time, category, name, data = ev[0], ev[1], ev[2], ev[3]
        if name == "metrics_updated":
            metrics.append((rel_time, data))

    print(f"\ntotal metrics_updated events: {len(metrics)}")

    if challenge_events:
        anchor = challenge_events[0][0]
    elif switch_time is not None:
        anchor = switch_time
    else:
        anchor = None

    if anchor is not None:
        print(f"\n--- metrics_updated within +/-1,500,000us of first path_challenge (t={anchor}) ---")
        # carry-forward last known value for fields not present in every event
        last = {}
        for t, data in metrics:
            last.update(data)
            if anchor - 1_500_000 <= t <= anchor + 1_500_000:
                marker = "  <== CHALLENGE SENT/SEEN" if abs(t - anchor) < 2000 else ""
                print(f"  t={t:>10} us  cwnd={last.get('cwnd'):>8}  bytes_in_flight={last.get('bytes_in_flight'):>8}  "
                      f"smoothed_rtt={last.get('smoothed_rtt'):>8}  min_rtt={last.get('min_rtt'):>8}  "
                      f"latest_rtt={last.get('latest_rtt'):>8}{marker}")

    # 5. Full compact cwnd/rtt time series (every Nth sample) for a broader view.
    print("\n--- full cwnd/rtt time series (every sample that changes cwnd or every 20th) ---")
    last = {}
    last_cwnd = None
    i = 0
    for t, data in metrics:
        last.update(data)
        i += 1
        cwnd = last.get('cwnd')
        show = (cwnd != last_cwnd) or (i % 20 == 0)
        if show:
            print(f"  t={t:>10} us  cwnd={cwnd!s:>8}  bytes_in_flight={last.get('bytes_in_flight')!s:>8}  "
                  f"smoothed_rtt={last.get('smoothed_rtt')!s:>8}  min_rtt={last.get('min_rtt')!s:>8}")
        last_cwnd = cwnd

if __name__ == "__main__":
    main()
