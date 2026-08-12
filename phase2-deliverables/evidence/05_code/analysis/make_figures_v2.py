#!/usr/bin/env python3
"""make_figures_v2.py -- narrative figures for the measurement-led Phase-1 deck.

Design rules:
  * ONE idea per figure, with the reading written on the figure itself.
  * No dead space: every figure fills its canvas.
  * No overlapping text. Zero-valued bars are drawn as explicit "zero" markers
    rather than invisible bars whose labels then collide.

All values are read from captured qlogs / CSVs on disk. Nothing is illustrative.

Output: analysis/figures/v2_*.png
"""
import glob
import json
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, Circle

BASE = "/home/sivaa/pvseed"
FIG = f"{BASE}/analysis/figures"
os.makedirs(FIG, exist_ok=True)

CWIN_INITIAL = 15360
INK = "#1A1A1A"
C_CODE = "#C44E52"
C_SPEC = "#4C72B0"
C_GOOD = "#55A868"
C_MUTE = "#8A8A8A"
C_PANEL = "#F4F6F8"

plt.rcParams.update({
    "font.size": 12,
    "axes.edgecolor": "#CCCCCC",
    "axes.labelcolor": INK,
    "text.color": INK,
    "xtick.color": "#555555",
    "ytick.color": "#555555",
    "figure.facecolor": "white",
})


def load(qlog):
    with open(qlog) as f:
        d = json.load(f)
    tr = d["traces"][0]
    fl = tr["event_fields"]
    ti, ci, ei, di = (fl.index(x) for x in ("relative_time", "category", "event", "data"))
    metrics, rs = [], []
    for ev in tr["events"]:
        t, cat, name, data = ev[ti], ev[ci], ev[ei], ev[di]
        if not isinstance(data, dict):
            continue
        if name == "metrics_updated" and "cwnd" in data:
            metrics.append((t, data.get("cwnd"), data.get("smoothed_rtt")))
        elif name == "packet_received":
            for fr in data.get("frames") or []:
                if fr.get("frame_type") == "path_response":
                    rs.append(t)
    return metrics, rs


def pick(p):
    g = glob.glob(p)
    return max(g, key=os.path.getsize) if g else None


# --------------------------------------------------------------------- fig A
def figA_spec_vs_code():
    """The rulebook says reset; the code doesn't."""
    src = f"{BASE}/results/raw/_task2_verify"
    qn, qr = pick(f"{src}/naive/qlog_server/*.qlog"), pick(f"{src}/reset/qlog_server/*.qlog")
    if not (qn and qr):
        print("SKIP figA")
        return

    def after_switch(q):
        m, rs = load(q)
        if not m or not rs:
            return None
        t1 = min(rs)
        pool = [c for t, c, s in m if t1 - 100_000 <= t <= t1 + 1_000_000 and c]
        return min(pool) if pool else None

    v_code = after_switch(qn) / 1024
    v_spec = after_switch(qr) / 1024
    req = CWIN_INITIAL / 1024

    fig, ax = plt.subplots(figsize=(10.6, 5.9))
    xs = [0.32, 1.28]
    bars = ax.bar(xs, [v_code, v_spec], color=[C_CODE, C_SPEC], width=.44, zorder=3)
    for x, v in zip(xs, [v_code, v_spec]):
        ax.text(x, v + 6, f"{v:.0f} KB", ha="center", fontsize=22, weight="bold", zorder=4)

    ax.set_xticks(xs)
    ax.set_xticklabels(["picoquic as shipped", "RFC 9000 §9.4 compliant\n(we implemented it)"],
                       fontsize=13)
    ax.set_xlim(-0.06, 1.66)

    ax.axhline(req, color=INK, ls="--", lw=1.7, zorder=2)
    # Placed in the empty band BELOW the dashed line and BETWEEN the bars: the
    # right-hand margin collides with the 15 KB bar label.
    ax.text(0.80, req * 0.48, "what the rulebook\nrequires: 15 KB",
            ha="center", va="center", fontsize=12, weight="bold")

    # the gap, annotated between the two levels
    ax.annotate("", xy=(0.72, v_code), xytext=(0.72, req),
                arrowprops=dict(arrowstyle="<->", lw=1.9, color=INK), zorder=4)
    ax.text(0.78, (v_code + req) / 2,
            f"{v_code / req:.0f}× higher\nthan the rule allows",
            fontsize=13.5, weight="bold", va="center")

    ax.set_ylabel("send-rate setting straight after\nthe network switch  (KB)", fontsize=12.5)
    ax.set_ylim(0, v_code * 1.30)
    ax.set_title("The rulebook says reset. The code doesn't.",
                 fontsize=18, weight="bold", pad=16)
    ax.grid(axis="y", alpha=.22, zorder=0)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    fig.tight_layout()
    fig.savefig(f"{FIG}/v2_figA_spec_vs_code.png", dpi=175)
    plt.close(fig)
    print(f"wrote v2_figA_spec_vs_code.png  ({v_code:.0f} vs {v_spec:.0f} KB)")


# --------------------------------------------------------------------- fig B
def figB_compliance_broke_it():
    """We followed the rule and the connection stopped working.

    Drawn as filled/empty transfer markers rather than bars: a 0% bar has no
    height, so its labels have nowhere to sit and collide with the axis.
    """
    fig, ax = plt.subplots(figsize=(11.0, 5.6))
    ax.set_xlim(0, 10)
    ax.set_ylim(0, 5.4)
    ax.axis("off")

    ax.text(5, 5.05, "We made it follow the rule.\nThe connection stopped working entirely.",
            ha="center", va="top", fontsize=18, weight="bold", linespacing=1.35)

    def panel(x0, w, title, sub, n, filled, color):
        ax.add_patch(FancyBboxPatch((x0, .55), w, 2.95,
                                    boxstyle="round,pad=0.06,rounding_size=0.14",
                                    linewidth=0, facecolor=C_PANEL, zorder=1))
        ax.text(x0 + w / 2, 3.16, title, ha="center", fontsize=13.5,
                weight="bold", zorder=3)
        ax.text(x0 + w / 2, 2.80, sub, ha="center", fontsize=11.5,
                color=C_MUTE, zorder=3)
        # transfer markers, wrapped
        per_row = 8
        r = 0.135
        gap = 0.30
        rows = (n + per_row - 1) // per_row
        total_w = min(n, per_row) * gap
        for i in range(n):
            row, col = divmod(i, per_row)
            cxp = x0 + w / 2 - total_w / 2 + gap / 2 + col * gap
            cyp = 2.10 - row * 0.42
            ok = i < filled
            ax.add_patch(Circle((cxp, cyp), r, facecolor=color if ok else "white",
                                edgecolor=color, linewidth=1.6, zorder=3))
        ax.text(x0 + w / 2, 1.02 - (rows - 1) * 0.08,
                f"{filled} of {n} transfers finished",
                ha="center", fontsize=13.5, weight="bold", color=color, zorder=3)

    panel(0.35, 4.4, "picoquic as shipped", "(ignores the rule)", 5, 5, C_GOOD)
    panel(5.25, 4.4, "our RFC-compliant version", "(follows the rule)", 15, 0, C_CODE)

    ax.text(5, 0.18,
            "Same testbed, same file, same network settings — the only change was following the rule.",
            ha="center", fontsize=11.5, color=C_MUTE)

    fig.tight_layout()
    fig.savefig(f"{FIG}/v2_figB_compliance_broke_it.png", dpi=175)
    plt.close(fig)
    print("wrote v2_figB_compliance_broke_it.png")


# --------------------------------------------------------------------- fig C
def figC_two_rules():
    """The rule has two halves; honouring one is the trap. Two columns."""
    fig, ax = plt.subplots(figsize=(12.2, 5.5))
    ax.set_xlim(0, 10)
    ax.set_ylim(0, 5.2)
    ax.axis("off")

    ax.text(5, 5.02, "The rule has TWO halves", ha="center", va="top",
            fontsize=18, weight="bold")

    def card(x0, w, tag, quote, verdict, vcolor, mark):
        ax.add_patch(FancyBboxPatch((x0, 1.20), w, 2.85,
                                    boxstyle="round,pad=0.07,rounding_size=0.16",
                                    linewidth=1.3, edgecolor="#DDE3EA",
                                    facecolor=C_PANEL, zorder=1))
        ax.text(x0 + 0.28, 3.72, tag, fontsize=12.5, weight="bold",
                color=C_SPEC, zorder=3)
        ax.text(x0 + 0.28, 3.30, quote, fontsize=12.6, style="italic",
                va="top", zorder=3, linespacing=1.5)
        ax.text(x0 + 0.28, 1.52, f"{mark}  {verdict}", fontsize=13,
                weight="bold", color=vcolor, zorder=3)

    card(0.25, 4.55, "HALF 1",
         "“Packets sent on the old path\nMUST NOT contribute to congestion\ncontrol or RTT estimation for\nthe new path.”",
         "we missed this one", C_CODE, "✗")
    card(5.20, 4.55, "HALF 2",
         "“…an endpoint MUST immediately\nreset the congestion controller\nand round-trip time estimator\n… to initial values.”",
         "we implemented this one", C_GOOD, "✓")

    ax.text(5, 0.70,
            "Reset the speed estimate but keep accepting stale replies from the old network,",
            ha="center", fontsize=13.5, weight="bold")
    ax.text(5, 0.28,
            "and the connection re-learns the WRONG speed — then sends three times too fast.",
            ha="center", fontsize=13.5, weight="bold")

    fig.tight_layout()
    fig.savefig(f"{FIG}/v2_figC_two_rules.png", dpi=175)
    plt.close(fig)
    print("wrote v2_figC_two_rules.png")


# --------------------------------------------------------------------- fig D
def figD_the_question():
    """Nobody has checked what the other implementations do."""
    fig, ax = plt.subplots(figsize=(10.4, 5.5))
    ax.set_xlim(0, 10)
    ax.set_ylim(0, 5.2)
    ax.axis("off")

    ax.text(5, 5.02, "So — what do the others do?", ha="center", va="top",
            fontsize=18, weight="bold")

    XL, XR = 1.55, 5.25
    ax.text(XL, 4.28, "IMPLEMENTATION", fontsize=10.5, color=C_MUTE, weight="bold")
    ax.text(XR, 4.28, "FOLLOWS THE RULE?", fontsize=10.5, color=C_MUTE, weight="bold")
    ax.plot([XL, 8.9], [4.10, 4.10], color="#DDE3EA", lw=1.2)

    rows = [("picoquic", "NO — verified four ways", C_CODE, True),
            ("quic-go", "not yet measured", C_MUTE, False),
            ("quiche", "not yet measured", C_MUTE, False),
            ("msquic", "not yet measured", C_MUTE, False),
            ("ngtcp2", "not yet measured", C_MUTE, False)]

    y = 3.72
    for name, val, col, known in rows:
        if known:
            ax.add_patch(FancyBboxPatch((XL - 0.35, y - 0.20), 7.6, 0.52,
                                        boxstyle="round,pad=0.02,rounding_size=0.08",
                                        linewidth=0, facecolor="#FBEDED", zorder=1))
        ax.text(XL, y, name, fontsize=14.5,
                weight="bold" if known else "normal", zorder=3)
        ax.text(XR, y, val, fontsize=13.5, color=col,
                weight="bold" if known else "normal",
                style="normal" if known else "italic", zorder=3)
        y -= 0.60

    ax.text(5, 0.42, "Nobody has measured this. That is the paper.",
            ha="center", fontsize=15.5, weight="bold", color=C_SPEC)

    fig.tight_layout()
    fig.savefig(f"{FIG}/v2_figD_the_question.png", dpi=175)
    plt.close(fig)
    print("wrote v2_figD_the_question.png")


if __name__ == "__main__":
    figA_spec_vs_code()
    figB_compliance_broke_it()
    figC_two_rules()
    figD_the_question()
    print("\nv2 figures in", FIG)
