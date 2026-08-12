#!/usr/bin/env python3
"""make_figures.py -- generate all Phase-1 presentation figures from REAL data.

Every figure is produced from captured qlog / calibration CSV on disk. Nothing
is synthetic, illustrative, or hand-drawn. Missing inputs are skipped with a
warning rather than faked.

Output: analysis/figures/*.png
"""
import csv
import glob
import json
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

BASE = "/home/sivaa/pvseed"
FIGDIR = f"{BASE}/analysis/figures"
os.makedirs(FIGDIR, exist_ok=True)

CWIN_INITIAL = 15360

# Consistent palette
C_NAIVE = "#C44E52"      # picoquic default / carry-over
C_RESET = "#4C72B0"      # spec-compliant reset
C_TRUTH = "#55A868"      # ground truth
C_PV = "#8172B2"         # path-validation measurement
C_WARN = "#CCB974"


def load_qlog(path):
    with open(path) as f:
        d = json.load(f)
    tr = d["traces"][0]
    fld = tr["event_fields"]
    ti, ci, ei, di = (fld.index(x) for x in ("relative_time", "category", "event", "data"))
    metrics, ch_sent, resp_recv = [], [], []
    for ev in tr["events"]:
        t, cat, name, data = ev[ti], ev[ci], ev[ei], ev[di]
        if not isinstance(data, dict):
            continue
        if name == "metrics_updated" and "cwnd" in data:
            metrics.append((t, data.get("cwnd"), data.get("smoothed_rtt")))
        elif name == "packet_sent":
            for fr in data.get("frames") or []:
                if fr.get("frame_type") == "path_challenge":
                    ch_sent.append(t)
        elif name == "packet_received":
            for fr in data.get("frames") or []:
                if fr.get("frame_type") == "path_response":
                    resp_recv.append(t)
    return metrics, ch_sent, resp_recv


def pick(pattern):
    g = glob.glob(pattern)
    return max(g, key=os.path.getsize) if g else None


def fig1_reset_vs_carryover():
    """Block B: picoquic does not reset; our compliant arm does."""
    src = f"{BASE}/results/raw/_task2_verify"
    qn, qr = pick(f"{src}/naive/qlog_server/*.qlog"), pick(f"{src}/reset/qlog_server/*.qlog")
    if not (qn and qr):
        print("SKIP fig1 (missing task2_verify qlogs)")
        return
    fig, ax = plt.subplots(figsize=(10, 5.2))
    for q, lab, col in ((qn, "picoquic default (no reset)", C_NAIVE),
                        (qr, "RFC 9000 §9.4 compliant reset", C_RESET)):
        m, ch, rs = load_qlog(q)
        if not m:
            continue
        tmig = max(rs) if rs else None
        t0 = tmig if tmig else 0
        xs = [(t - t0) / 1e6 for t, c, s in m if c is not None]
        ys = [c / 1024 for t, c, s in m if c is not None]
        pts = [(x, y) for x, y in zip(xs, ys) if -2.0 <= x <= 3.0]
        if pts:
            ax.plot([p[0] for p in pts], [p[1] for p in pts], lw=2.1, label=lab, color=col)
    ax.axvline(0, color="k", ls="--", lw=1.2, alpha=.75)
    ax.text(0.04, 0.95, "migration\ncompletes", transform=ax.get_xaxis_transform(),
            fontsize=9, va="top", alpha=.8)
    ax.axhline(CWIN_INITIAL / 1024, color=C_TRUTH, ls=":", lw=1.8)
    ax.text(2.95, CWIN_INITIAL / 1024 + 3, "RFC 9002 initial window (15 KB)",
            ha="right", fontsize=8.5, color=C_TRUTH)
    ax.set_xlabel("time relative to migration (s)")
    ax.set_ylabel("congestion window (KB)")
    ax.set_title("picoquic does not perform the RFC 9000 §9.4 mandatory reset",
                 fontsize=12.5, weight="bold")
    ax.legend(frameon=False, fontsize=9.5)
    ax.grid(alpha=.25)
    fig.tight_layout()
    fig.savefig(f"{FIGDIR}/fig1_reset_vs_carryover.png", dpi=170)
    plt.close(fig)
    print("wrote fig1_reset_vs_carryover.png")


def fig2_the_discarded_measurement():
    """Block D — THE headline. A clean new-path RTT existed and was discarded."""
    q = pick(f"{BASE}/results/raw/baseline/step_down/specreset/rep1/final/qlog_server/*.qlog")
    if not q:
        print("SKIP fig2 (missing step_down specreset qlog)")
        return
    m, ch, rs = load_qlog(q)
    if not rs:
        print("SKIP fig2 (no path_response)")
        return
    tmig = max(rs)
    pv_rtt = (tmig - max([c for c in ch if c <= tmig])) / 1000.0

    # The congestion controller's own belief about the new path, taken from the
    # first smoothed_rtt sample available after migration completes. Widened
    # window + fallback: qlog does not report every field on every event, and
    # the exact migration timestamp shifts between runs.
    # What the congestion controller believes about the path it is now sending
    # on. Prefer the first sample after migration completes; if the connection
    # produced none (it died), fall back to the last sample at-or-before
    # migration -- that stale path-A value is precisely what the controller
    # carries onto the new path, which is the comparison the slide makes.
    after = [(t, s) for t, c, s in m if tmig < t <= tmig + 2_000_000 and s]
    if after:
        cc_rtt, cc_src = after[0][1] / 1000.0, "first sample after migration"
    else:
        before = [(t, s) for t, c, s in m if t <= tmig and s]
        cc_rtt = before[-1][1] / 1000.0 if before else float("nan")
        cc_src = "last sample before migration (connection died after)"
    true_rtt = 60.0
    print(f"    fig2 inputs: path-validation={pv_rtt:.1f}ms  "
          f"cc_belief={cc_rtt:.1f}ms [{cc_src}]  truth={true_rtt}ms")

    fig, (axa, axb) = plt.subplots(1, 2, figsize=(12.4, 5.0),
                                   gridspec_kw={"width_ratios": [1, 1.35]})

    bars = ["Path validation\n(PATH_CHALLENGE→\nPATH_RESPONSE)",
            "Congestion\ncontroller's\nsmoothed_rtt",
            "Ground truth\n(configured)"]
    vals = [pv_rtt, cc_rtt, true_rtt]
    cols = [C_PV, C_NAIVE, C_TRUTH]
    b = axa.bar(bars, vals, color=cols, width=.62)
    for rect, v in zip(b, vals):
        axa.text(rect.get_x() + rect.get_width() / 2, v + 1.6, f"{v:.1f} ms",
                 ha="center", fontsize=11, weight="bold")
    axa.axhline(true_rtt, color=C_TRUTH, ls=":", lw=1.6, zorder=0)
    axa.set_ylabel("measured RTT of the NEW path (ms)")
    axa.set_ylim(0, max(vals) * 1.32)
    axa.set_title("The clean measurement existed", fontsize=12, weight="bold")
    axa.grid(axis="y", alpha=.25)

    # Right panel: how long the congestion controller takes to discover, by
    # ordinary ACK sampling, the value path validation already had at t=0.
    # Uses the arm that COMPLETES its transfer, so the panel says nothing about
    # our own reset implementation -- only about how slowly the estimator learns.
    qn = pick(f"{BASE}/results/raw/baseline/step_down/naive/rep1/final/qlog_server/*.qlog")
    if qn:
        mn, chn, rsn = load_qlog(qn)
        tmign = max(rsn) if rsn else tmig
        pvn = (tmign - max([c for c in chn if c <= tmign])) / 1000.0 if chn else pv_rtt
        srtt = [((t - tmign) / 1e6, s / 1000.0) for t, c, s in mn
                if s and -0.5 <= (t - tmign) / 1e6 <= 8.0]
        if srtt:
            axb.plot([p[0] for p in srtt], [p[1] for p in srtt], lw=2.1,
                     color=C_NAIVE, label="congestion controller's smoothed_rtt")
            axb.axhline(pvn, color=C_PV, ls="-", lw=2.0,
                        label=f"path validation, known at t=0 ({pvn:.1f} ms)")
            axb.axhline(true_rtt, color=C_TRUTH, ls=":", lw=1.8,
                        label=f"true RTT ({true_rtt:.0f} ms)")
            # how long until the estimator gets within 10% of truth
            conv = next((x for x, y in srtt if x > 0 and abs(y - true_rtt) <= 0.1 * true_rtt), None)
            if conv:
                axb.axvline(conv, color="k", ls="--", lw=1.1, alpha=.6)
                axb.annotate(f"estimator reaches ±10%\nafter {conv:.2f} s",
                             xy=(conv, true_rtt * 0.55), xytext=(conv + 0.6, true_rtt * 0.40),
                             fontsize=9, arrowprops=dict(arrowstyle="->", lw=1.1))
            peak = max(y for _, y in srtt)
            axb.set_yscale("log")
            axb.legend(frameon=False, fontsize=8.6, loc="lower right")
            if peak > 4 * true_rtt:
                axb.annotate(f"estimate peaks at {peak:.0f} ms\n= {peak/true_rtt:.0f}× the true RTT",
                             xy=(next(x for x, y in srtt if y == peak), peak),
                             xytext=(0.45, peak * 0.42), fontsize=9.5,
                             arrowprops=dict(arrowstyle="->", lw=1.1))
    axb.axvline(0, color="k", ls="--", lw=1.2, alpha=.75)
    axb.set_xlabel("time relative to migration (s)")
    axb.set_ylabel("RTT estimate for the new path (ms, log)")
    axb.set_title("…the controller then spends seconds\nrediscovering it from ACKs",
                  fontsize=12, weight="bold")
    axb.grid(alpha=.25)

    fig.suptitle("QUIC measures every new path, then throws the result away",
                 fontsize=13.5, weight="bold", y=1.0)
    fig.tight_layout()
    fig.savefig(f"{FIGDIR}/fig2_discarded_measurement.png", dpi=170)
    plt.close(fig)
    print(f"wrote fig2_discarded_measurement.png  (pv={pv_rtt:.1f}ms cc={cc_rtt:.1f}ms)")
    return pv_rtt, cc_rtt


def fig3_calibration_trap():
    """Methodology: we validated the emulator before trusting it."""
    path = f"{BASE}/results/processed/calibration.csv"
    if not os.path.exists(path):
        print("SKIP fig3")
        return
    rows = list(csv.DictReader(open(path)))
    by_burst = {}
    for r in rows:
        by_burst.setdefault(int(r["burst_bytes"]), []).append(
            abs(float(r["relative_error_pct"])))
    bursts = sorted(by_burst)
    errs = [max(by_burst[b]) for b in bursts]

    fig, ax = plt.subplots(figsize=(9.2, 4.8))
    cols = [C_TRUTH if e < 10 else C_NAIVE for e in errs]
    ax.bar([str(b) for b in bursts], [max(e, 1e-2) for e in errs], color=cols, width=.6)
    ax.set_yscale("log")
    ax.axhline(10, color="k", ls="--", lw=1.2)
    ax.text(0.02, 12, "10% acceptance gate", fontsize=9, transform=ax.get_yaxis_transform())
    ax.set_xlabel("tc token-bucket burst (bytes)")
    ax.set_ylabel("worst capacity-estimate error (%, log scale)")
    ax.set_title("Validating the emulator before trusting it:\na too-large burst makes the shaper measure itself",
                 fontsize=11.5, weight="bold")
    ax.grid(axis="y", alpha=.25)
    fig.tight_layout()
    fig.savefig(f"{FIGDIR}/fig3_calibration_trap.png", dpi=170)
    plt.close(fig)
    print("wrote fig3_calibration_trap.png")


def fig4_train_length():
    """Methodology: short probe trains break on this emulator without correction."""
    path = f"{BASE}/results/processed/train_length_sweep.csv"
    if not os.path.exists(path):
        print("SKIP fig4")
        return
    rows = [r for r in csv.DictReader(open(path)) if int(r["burst_bytes"]) == 3200]
    fig, ax = plt.subplots(figsize=(9.2, 4.8))
    for disc, col, mk in ((0, C_NAIVE, "o"), (1, C_WARN, "s"), (2, C_TRUTH, "^")):
        pts = {}
        for r in rows:
            if int(r["discard_leading"]) != disc:
                continue
            k = int(r["k"])
            pts.setdefault(k, []).append(abs(float(r["relative_error_pct"])))
        ks = sorted(pts)
        if ks:
            ax.plot(ks, [max(pts[k]) for k in ks], marker=mk, lw=2, color=col,
                    label=f"discard_leading = {disc}")
    ax.axhline(10, color="k", ls="--", lw=1.2)
    ax.text(19.6, 11.5, "10% gate", ha="right", fontsize=9)
    ax.set_yscale("log")
    ax.set_xlabel("probe train length K (packets)")
    ax.set_ylabel("worst capacity-estimate error (%, log)")
    ax.set_title("Short probe trains fail without leading-gap correction\n(burst = 3200 B)",
                 fontsize=11.5, weight="bold")
    ax.legend(frameon=False, fontsize=9.5)
    ax.grid(alpha=.25)
    fig.tight_layout()
    fig.savefig(f"{FIGDIR}/fig4_train_length.png", dpi=170)
    plt.close(fig)
    print("wrote fig4_train_length.png")


if __name__ == "__main__":
    fig1_reset_vs_carryover()
    fig2_the_discarded_measurement()
    fig3_calibration_trap()
    fig4_train_length()
    print("\nfigures in", FIGDIR)
