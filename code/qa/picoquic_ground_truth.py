#!/usr/bin/env python3
"""Ground truth for the five picoquic repetitions, from the qlog only.

Our own harness prints an intent line to stdout and explicitly warns that it is
not wire-truth. So verify on the wire instead:

  1. Did the CLIENT ADDRESS actually change, and was it an IP change rather than
     a port-only rebinding? RFC 9000 s9.4 exempts port-only changes, so a
     port-only run would prove nothing.
  2. What is the effective per-packet size, and therefore picoquic's effective
     initial and minimum congestion window? PICOQUIC_CWIN_INITIAL is
     10 * PICOQUIC_MAX_PACKET_SIZE = 15,360 B by the constant, but picoquic
     computes from the negotiated path MTU, so the effective value differs.
  3. Did the window ever take the value a reset would produce?
"""
import glob
import json
import os
import re
from collections import Counter

R = "/home/sivaa/pvseed/results/raw/picoquic/reps"


def load(path):
    doc = json.load(open(path))
    tr = doc["traces"][0] if "traces" in doc else doc
    return tr.get("events", [])


def addr_pairs(events):
    """Collect every distinct (addr_from, addr_to) seen on packet events."""
    seen = Counter()
    for e in events:
        if not (isinstance(e, list) and len(e) >= 4):
            continue
        d = e[3]
        if not isinstance(d, dict):
            continue
        a, b = d.get("addr_from"), d.get("addr_to")
        if a or b:
            def fmt(x):
                if isinstance(x, dict):
                    return f"{x.get('ip_v4') or x.get('ip')}:{x.get('port_v4') or x.get('port')}"
                return str(x)
            seen[(fmt(a), fmt(b))] += 1
    return seen


print(f"{'rep':>4}  {'client addrs seen (ip:port)':<44} {'IP change?':<11} {'port change?'}")
print("-" * 88)
summary = []
for i in range(1, 6):
    fs = sorted(glob.glob(f"{R}/rep_{i}/qlog_server/*.qlog"), key=os.path.getsize, reverse=True)
    if not fs:
        print(f"{i:>4}  no server qlog")
        continue
    ev = load(fs[0])
    pairs = addr_pairs(ev)
    # On the SERVER, the peer (client) address is addr_from on received packets.
    clients = Counter()
    for (a, b), n in pairs.items():
        for x in (a, b):
            if x and re.match(r"10\.0\.[13]\.1:", x):
                clients[x] += n
    ips = {c.split(":")[0] for c in clients}
    ports = {c.split(":")[1] for c in clients}
    ip_change = len(ips) > 1
    port_change = len(ports) > 1
    shown = ", ".join(sorted(clients)) or "(none seen)"
    print(f"{i:>4}  {shown:<44} {'YES' if ip_change else 'NO':<11} {'YES' if port_change else 'NO'}")
    summary.append((i, ip_change, port_change, ips))

print()
print("=== effective packet size and derived windows (rep 1) ===")
fs = sorted(glob.glob(f"{R}/rep_1/qlog_server/*.qlog"), key=os.path.getsize, reverse=True)
if fs:
    ev = load(fs[0])
    sizes = Counter()
    for e in ev:
        if isinstance(e, list) and len(e) >= 4 and isinstance(e[3], dict):
            hdr = e[3].get("header") or {}
            n = e[3].get("packet_size") or hdr.get("packet_size")
            if isinstance(n, int) and n > 200:
                sizes[n] += 1
    top = sizes.most_common(3)
    print(f"  most common packet sizes: {top}")
    if top:
        mtu = top[0][0]
        print(f"  -> effective send size {mtu} B")
        print(f"     10 x {mtu} = {10*mtu:,} B would be the effective initial window")
        print(f"      2 x {mtu} = {2*mtu:,} B would be the effective minimum window")
    print(f"  constant-based initial window: 10 x 1536 = 15,360 B")

print()
print("=== did the window EVER take a reset-shaped value? ===")
import csv
for i in range(1, 6):
    f = f"{R}/rep_{i}/server_metrics.csv"
    if not os.path.exists(f):
        continue
    vals = []
    for row in csv.DictReader(open(f)):
        try:
            t, c = float(row["time_us"]), float(row["cwnd"])
        except Exception:
            continue
        vals.append((t, c))
    post = [(t, c) for t, c in vals if 4_980_000 <= t <= 5_300_000]
    lo = min((c for _, c in post), default=float("nan"))
    hits15360 = sum(1 for _, c in post if abs(c - 15360) < 1e-6)
    hits14240 = sum(1 for _, c in post if abs(c - 14240) < 1e-6)
    print(f"  rep {i}: min={lo:>9,.0f} B   samples==15,360: {hits15360}   samples==14,240: {hits14240}")
