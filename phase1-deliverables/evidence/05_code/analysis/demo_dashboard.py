#!/usr/bin/env python3
"""demo_dashboard.py -- terminal live dashboard for the Phase-1 demo video.

Replays a REAL captured qlog in real time. Every number shown is read from the
trace on disk; nothing is simulated. Replay is used rather than a live run so
the recording is deterministic (live migration has a known ~1-in-5 stall) --
the data is identical either way.

    python3 demo_dashboard.py [--speed 2.0] [--qlog PATH]

Ctrl-C exits cleanly.
"""
import argparse
import glob
import json
import os
import shutil
import sys
import time

try:
    import plotext as plt
except ImportError:
    sys.exit("need plotext:  pip3 install --break-system-packages plotext")

BASE = "/home/sivaa/pvseed"
TRUE_RTT_MS = 60.0
TRUE_RATE_MBIT = 20
CWIN_INITIAL = 15360

C_OK, C_HOT, C_KEY, C_DIM = "\033[92m", "\033[91m", "\033[95m", "\033[90m"
C_B, C_R = "\033[1m", "\033[0m"


def cls():
    print("\033[2J\033[H", end="")


def rule(ch="─"):
    return C_DIM + ch * min(shutil.get_terminal_size((100, 30)).columns, 100) + C_R


def banner(line1, line2=""):
    cls()
    print()
    print(rule("═"))
    print(f"  {C_B}{line1}{C_R}")
    if line2:
        print(f"  {C_DIM}{line2}{C_R}")
    print(rule("═"))


def load(qlog):
    with open(qlog) as f:
        d = json.load(f)
    tr = d["traces"][0]
    fld = tr["event_fields"]
    ti, ci, ei, di = (fld.index(x) for x in ("relative_time", "category", "event", "data"))
    metrics, ch, rs = [], [], []
    for ev in tr["events"]:
        t, cat, name, data = ev[ti], ev[ci], ev[ei], ev[di]
        if not isinstance(data, dict):
            continue
        if name == "metrics_updated" and "cwnd" in data:
            metrics.append((t, data.get("cwnd"), data.get("smoothed_rtt")))
        elif name == "packet_sent":
            for fr in data.get("frames") or []:
                if fr.get("frame_type") == "path_challenge":
                    ch.append(t)
        elif name == "packet_received":
            for fr in data.get("frames") or []:
                if fr.get("frame_type") == "path_response":
                    rs.append(t)
    return metrics, ch, rs


def frame(metrics, upto_idx, tmig, pv_rtt, phase):
    cls()
    w = min(shutil.get_terminal_size((100, 30)).columns, 100)
    print(f"\n  {C_B}PV-Seed · Phase 1 demo{C_R}   "
          f"{C_DIM}replaying captured qlog · picoquic · Linux netns testbed{C_R}")
    print(f"  {C_DIM}path A: 100 Mbit / 20 ms      →      path B: {TRUE_RATE_MBIT} Mbit / "
          f"{TRUE_RTT_MS:.0f} ms{C_R}")
    print(rule())

    pts = metrics[:upto_idx]
    xs = [(t - tmig) / 1e6 for t, c, s in pts if c is not None]
    ys = [c / 1024 for t, c, s in pts if c is not None]

    plt.clf()
    plt.plotsize(w, 17)
    plt.theme("pro")
    if xs:
        plt.plot(xs, ys, marker="braille", color="red+")
    plt.vline(0, color="white")
    plt.title("congestion window (KB)   —   vertical line = migration")
    plt.xlabel("time relative to migration (s)")
    plt.show()

    print(rule())
    cur = pts[-1] if pts else (0, 0, 0)
    t_rel = (cur[0] - tmig) / 1e6
    cw = (cur[1] or 0) / 1024
    srtt = (cur[2] or 0) / 1000.0

    if phase == "pre":
        print(f"  t = {t_rel:+6.2f} s   cwnd = {cw:7.1f} KB   "
              f"transfer running on path A")
    elif phase == "mig":
        print(f"  {C_HOT}{C_B}▶ MIGRATION — client moves 10.0.1.1 → 10.0.3.1{C_R}")
        print(f"  {C_DIM}  server must validate the new address before trusting it{C_R}")
    elif phase == "pv":
        print(f"  {C_KEY}{C_B}▶ PATH_CHALLENGE sent … PATH_RESPONSE received{C_R}")
        print(f"  {C_KEY}    new-path RTT measured = {pv_rtt:.1f} ms   "
              f"(ground truth {TRUE_RTT_MS:.0f} ms — error "
              f"{abs(pv_rtt-TRUE_RTT_MS)/TRUE_RTT_MS*100:.1f}%){C_R}")
        print(f"  {C_DIM}    RFC 9000 §9.4 requires this result to be discarded.{C_R}")
    else:
        err = abs(srtt - TRUE_RTT_MS) / TRUE_RTT_MS * 100 if srtt else 0
        col = C_OK if err < 15 else C_HOT
        print(f"  t = {t_rel:+6.2f} s   cwnd = {cw:7.1f} KB")
        print(f"  {C_KEY}path validation knew: {pv_rtt:5.1f} ms{C_R}     "
              f"{col}congestion controller believes: {srtt:7.1f} ms  "
              f"({err:5.0f}% off){C_R}")
    sys.stdout.flush()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--speed", type=float, default=2.0, help="replay speed multiplier")
    ap.add_argument("--qlog")
    args = ap.parse_args()

    q = args.qlog
    if not q:
        g = glob.glob(f"{BASE}/results/raw/baseline/step_down/naive/rep1/final/qlog_server/*.qlog")
        if not g:
            sys.exit("no qlog found — pass --qlog")
        q = max(g, key=os.path.getsize)

    metrics, ch, rs = load(q)
    if not rs:
        sys.exit("no path_response in trace")
    tmig = max(rs)
    pv_rtt = (tmig - max([c for c in ch if c <= tmig])) / 1000.0

    banner("QUIC pays for a speed test on every new network — then ignores it.",
           f"replaying: {os.path.basename(q)}")
    time.sleep(3.5)

    idx_mig = next((i for i, (t, c, s) in enumerate(metrics) if t >= tmig), len(metrics) // 2)

    # ---- pre-migration
    start = max(0, idx_mig - 26)
    for i in range(start, idx_mig):
        frame(metrics, i + 1, tmig, pv_rtt, "pre")
        time.sleep(0.10 / args.speed)

    # ---- migration
    frame(metrics, idx_mig, tmig, pv_rtt, "mig")
    time.sleep(3.0)

    # ---- the measurement
    frame(metrics, idx_mig, tmig, pv_rtt, "pv")
    time.sleep(5.0)

    # ---- divergence
    for i in range(idx_mig, min(idx_mig + 55, len(metrics))):
        frame(metrics, i + 1, tmig, pv_rtt, "post")
        time.sleep(0.14 / args.speed)

    after = [s / 1000.0 for t, c, s in metrics if t > tmig and s]
    peak = max(after) if after else 0

    cls()
    print()
    print(rule("═"))
    print(f"  {C_B}What this trace shows{C_R}")
    print(rule("═"))
    print()
    print(f"   {C_KEY}PATH_CHALLENGE → PATH_RESPONSE measured{C_R}   "
          f"{C_B}{pv_rtt:6.1f} ms{C_R}")
    print(f"   ground truth (configured)                {C_B}{TRUE_RTT_MS:6.1f} ms{C_R}   "
          f"{C_OK}error {abs(pv_rtt-TRUE_RTT_MS)/TRUE_RTT_MS*100:.1f}%{C_R}")
    print()
    print(f"   {C_HOT}the congestion controller instead believed{C_R}  "
          f"{C_B}{after[0] if after else 0:6.1f} ms{C_R}")
    print(f"   {C_HOT}and peaked at{C_R}                             "
          f"{C_B}{peak:6.1f} ms{C_R}   "
          f"{C_HOT}({peak/TRUE_RTT_MS:.0f}× the truth){C_R}")
    print()
    print(rule())
    print(f"  {C_B}The clean measurement existed. RFC 9000 §9.4 requires discarding it.{C_R}")
    print(f"  {C_DIM}PV-Seed reads it instead — with a fallback that is exactly what the RFC wanted.{C_R}")
    print(rule("═"))
    print()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        cls()
        print("interrupted")
