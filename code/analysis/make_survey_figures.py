#!/usr/bin/env python3
"""make_survey_figures.py -- Phase-2 figures, generated from survey_results.json.

Everything is data-driven: adding an implementation to survey_results.json makes
it appear in every figure with no code change. Implementations still marked
in_progress/pending render as "not yet audited" rather than being hidden, so a
partial survey is visibly partial instead of silently incomplete.

Output: analysis/figures/p2_*.png
"""
import json
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch

BASE = "/home/sivaa/pvseed"
FIG = f"{BASE}/analysis/figures"
DATA = f"{BASE}/analysis/survey_results.json"
os.makedirs(FIG, exist_ok=True)

INK = "#1A1A1A"
RED = "#C44E52"      # violates / absent
GREEN = "#55A868"    # complies
BLUE = "#4C72B0"     # neutral / structural
AMBER = "#CCB974"    # inert / partial
MUTE = "#9AA0A6"     # unknown
PANEL = "#F4F6F8"

plt.rcParams.update({
    "font.size": 12, "text.color": INK, "axes.labelcolor": INK,
    "xtick.color": "#555", "ytick.color": "#555",
    "axes.edgecolor": "#CCC", "figure.facecolor": "white",
})

with open(DATA) as f:
    D = json.load(f)
IMPLS = D["implementations"]
DONE = [i for i in IMPLS if i["status"] == "done"]


# --- text fitting -----------------------------------------------------------
# matplotlib's wrap=True wraps to the FIGURE, not to the box you drew, so a long
# label happily runs straight across its neighbours. With three columns nothing
# overflowed and this went unnoticed; at five columns the card labels collided
# into an unreadable smear. Fit explicitly to the card instead.
CHAR_W = 0.52  # width of an average glyph, in em, for the default sans face


def _est_width_in(text, fontsize, bold=False):
    # CHAR_W is calibrated on mixed-case prose. An all-caps word is far wider
    # per glyph -- estimating ASYMMETRIC at the prose average said it fit its
    # card when it did not.
    w = CHAR_W
    if text and sum(c.isupper() for c in text) / len(text) > 0.6:
        w = 0.70
    if bold:
        w *= 1.06
    return w * fontsize * len(text) / 72.0


def fit_fontsize(text, width_in, base, floor=7.0, bold=False):
    """Shrink a single-line label until it fits width_in."""
    est = _est_width_in(text, base, bold)
    return base if est <= width_in else max(floor, base * width_in / est)


def wrap_to(text, width_in, fontsize, max_lines=None):
    """Wrap to a box width in inches, breaking over-long tokens (identifiers
    like picoquic_congestion_notification_reset contain no spaces to break at)."""
    per_line = max(int(width_in * 72.0 / (CHAR_W * fontsize)), 8)
    words, lines, line = [], [], ""
    for w in text.split():
        while len(w) > per_line:
            words.append(w[:per_line])
            w = w[per_line:]
        words.append(w)
    for w in words:
        if line and len(line) + 1 + len(w) > per_line:
            lines.append(line)
            line = w
        else:
            line = (line + " " + w).strip()
    if line:
        lines.append(line)
    return "\n".join(lines[:max_lines] if max_lines else lines)


def answer_style(ans):
    # ASYMMETRIC / SPLIT were introduced by msquic: a binary yes/no cannot
    # express "the observer resets but the initiator does not" (Q1) or
    # "RTT is excluded but bytes-acked are not" (Q3). Rendering those as a
    # plain YES or NO would misreport the finding.
    return {
        "YES":        (GREEN, "YES"),
        "NO":         (RED,   "NO"),
        "INERT":      (AMBER, "present\nbut inert"),
        "ASYMMETRIC": (AMBER, "ASYMMETRIC\nsender yes\nmover no"),
        "SPLIT":      (AMBER, "SPLIT\nRTT yes\ncwnd no"),
        "N/A":        (MUTE,  "n/a"),
    }.get(ans, (MUTE, "not yet\naudited"))


# ------------------------------------------------------------------ figure 1
def fig_compliance_table():
    """The survey's centrepiece: who complies with what."""
    n = len(IMPLS)
    # The row-label gutter was 3.25in wide for labels that need about 1.85in,
    # which left a dead band down the left and made the table look shoved to
    # the right on the slide. Size the gutter to the labels.
    W = 2.05 * n + 2.95
    fig, ax = plt.subplots(figsize=(W, 6.4))
    ax.set_xlim(0, W); ax.set_ylim(0, 6.4); ax.axis("off")

    ax.text(W / 2, 6.15, "Congestion control at connection migration",
            ha="center", va="top", fontsize=18, weight="bold")
    ax.text(W / 2, 5.72,
            f"{len(DONE)} of {n} implementations audited",
            ha="center", va="top", fontsize=12, color=MUTE)

    rows = [
        ("q1", "Resets congestion\ncontrol on migration?", "MUST"),
        ("q2", "Uses the free\npath-validation RTT?", "MAY"),
        ("q3", "Ignores stale replies\nfrom the old network?", "MUST"),
    ]
    x0, colw, rowh = 2.60, 2.05, 1.28
    lab_x = x0 - 0.20
    ytop = 4.62

    for j, im in enumerate(IMPLS):
        cx = x0 + j * colw + colw / 2
        ax.text(cx, ytop + 0.52, im["name"], ha="center", fontsize=13.5,
                weight="bold", color=INK if im["status"] == "done" else MUTE)
        # Flag any implementation whose answers were not cross-checked against a
        # running program. Presenting a source-only row identically to a
        # source+live one would overstate the evidence.
        sub = im["language"]
        if im.get("source_only"):
            sub += "  ·  source only"
        ax.text(cx, ytop + 0.22, sub, ha="center", fontsize=9.5,
                color=AMBER if im.get("source_only") else MUTE,
                weight="bold" if im.get("source_only") else "normal")

    for i, (key, label, req) in enumerate(rows):
        ry = ytop - i * rowh
        ax.text(lab_x, ry - rowh / 2 + 0.15, label, ha="right", va="center", fontsize=12)
        ax.text(lab_x, ry - rowh / 2 - 0.30, req, ha="right", va="center",
                fontsize=10, weight="bold", color=BLUE)
        for j, im in enumerate(IMPLS):
            cx = x0 + j * colw
            col, txt = answer_style(im[key]["answer"])
            ax.add_patch(FancyBboxPatch((cx + 0.07, ry - rowh + 0.12), colw - 0.14, rowh - 0.22,
                                        boxstyle="round,pad=0.02,rounding_size=0.09",
                                        linewidth=0, facecolor=col, alpha=.16, zorder=1))
            ax.text(cx + colw / 2, ry - rowh / 2 + 0.02, txt, ha="center", va="center",
                    fontsize=15 if len(txt) <= 3 else 11,
                    weight="bold", color=col, zorder=3)

    # Caption derived from the data, not asserted. An earlier hand-written
    # version claimed "no two answer the same way", which is false -- quic-go
    # and quiche answer identically. What actually differs is the mechanism.
    triples = {(im["q1"]["answer"], im["q2"]["answer"], im["q3"]["answer"]) for im in DONE}
    # ASYMMETRIC and SPLIT are PARTIAL failures of a MUST, not passes: in msquic
    # the migrating endpoint does not reset, and bytes-acked are not excluded.
    # Counting only "NO" would undercount non-compliance.
    def musts(im):
        return (im["q1"]["answer"], im["q3"]["answer"])
    full = [im["name"] for im in DONE if "NO" in musts(im)]
    part = [im["name"] for im in DONE
            if im["name"] not in full and {"ASYMMETRIC", "SPLIT"} & set(musts(im))]
    fails = full + [f"{p} (partly)" for p in part]
    q2_no = all(im["q2"]["answer"] in ("NO", "INERT") for im in DONE) and DONE
    bits = [f"{len(triples)} distinct answer patterns across {len(DONE)} implementations"]
    if fails:
        bits.append(f"{', '.join(fails)} fails at least one MUST")
    cap = ".  ".join(bits) + "."
    ax.text(W / 2, 0.52, cap, ha="center", fontsize=12.5, weight="bold")
    if q2_no:
        ax.text(W / 2, 0.16,
                "Not one of them uses the free measurement the protocol already takes.",
                ha="center", fontsize=12, color=RED, weight="bold")
    fig.tight_layout()
    fig.savefig(f"{FIG}/p2_fig1_compliance_table.png", dpi=175)
    plt.close(fig)
    print("wrote p2_fig1_compliance_table.png")


# ------------------------------------------------------------------ figure 2
def fig_dead_hooks():
    """Two of three ship a reset hook that nothing calls."""
    cards = [im for im in DONE if im.get("reset_hook")]
    # Width scales with the number of cards; a fixed 11.4in was sized for three
    # and left no room for five.
    figw = 2.5 * max(len(cards), 1) + 1.6
    fig, ax = plt.subplots(figsize=(figw, 5.6))
    ax.set_xlim(0, 10); ax.set_ylim(0, 5.4); ax.axis("off")
    ax.text(5, 5.15, "The code to obey the rule exists.\nIn most cases, nothing calls it.",
            ha="center", va="top", fontsize=17, weight="bold", linespacing=1.35)

    w = 9.4 / max(len(cards), 1)
    card_in = (w - 0.24) * figw / 10.0   # card width in inches
    for k, im in enumerate(cards):
        h = im["reset_hook"]
        dead = h.get("dead")
        col = RED if dead else GREEN
        x0 = 0.3 + k * w
        ax.add_patch(FancyBboxPatch((x0, 1.05), w - 0.24, 2.75,
                                    boxstyle="round,pad=0.05,rounding_size=0.14",
                                    linewidth=1.2, edgecolor="#DDE3EA",
                                    facecolor=PANEL, zorder=1))
        ax.text(x0 + (w - 0.24) / 2, 3.50, im["name"], ha="center",
                fontsize=14, weight="bold", zorder=3)
        ax.text(x0 + (w - 0.24) / 2, 3.12, h["name"], ha="center",
                fontsize=fit_fontsize(h["name"], card_in * 0.96, 9.5),
                style="italic", color=MUTE, zorder=3)
        ax.text(x0 + (w - 0.24) / 2, 2.42, f"{h['callers']}", ha="center",
                fontsize=40, weight="bold", color=col, zorder=3)
        ax.text(x0 + (w - 0.24) / 2, 1.92, "call sites", ha="center",
                fontsize=11, color=MUTE, zorder=3)
        ax.text(x0 + (w - 0.24) / 2, 1.35, "DEAD CODE" if dead else "reachable",
                ha="center", fontsize=12, weight="bold", color=col, zorder=3)

    # Precise, data-derived. An earlier version said "the same dead hook",
    # which misreads quic-go -- its handler IS reachable. Name the count.
    dead = [im["name"] for im in cards if (im["reset_hook"] or {}).get("dead")]
    live_ = [im["name"] for im in cards if not (im["reset_hook"] or {}).get("dead")]
    line1 = (f"{len(dead)} of {len(cards)} ship a migration-reset hook that nothing calls"
             f" ({', '.join(dead)}).")
    ax.text(5, 0.60, line1, ha="center", fontsize=12.5, weight="bold")
    if live_:
        ax.text(5, 0.24,
                f"Independent codebases, different languages — only {', '.join(live_)} "
                f"actually calls its own.",
                ha="center", fontsize=11.5, color=MUTE)
    fig.tight_layout()
    fig.savefig(f"{FIG}/p2_fig2_dead_hooks.png", dpi=175)
    plt.close(fig)
    print("wrote p2_fig2_dead_hooks.png")


# ------------------------------------------------------------------ figure 3
def fig_mechanisms():
    """Same outcome, different mechanism -- the taxonomy."""
    figw = 2.75 * max(len(DONE), 1) + 1.6
    w = 9.4 / max(len(DONE), 1)
    card_in = (w - 0.24) * figw / 10.0

    # Wrap first, then size the cards to the tallest one. A fixed 3.75-unit card
    # left a third of every card empty below the text, and the figure carried
    # that dead space onto the slide.
    IPU = 1.035                                   # inches per y-unit
    MECH_TOP, MECH_FS, MECH_LS = 2.92, 9.5, 1.4
    lh = (MECH_FS * MECH_LS / 72.0) / IPU         # line height, in y-units
    mech = {im["name"]: wrap_to(im["q1"].get("mechanism", ""), card_in * 0.90,
                                MECH_FS, max_lines=7) for im in DONE}
    max_lines = max((t.count("\n") + 1 for t in mech.values()), default=1)
    card_bot = MECH_TOP - max_lines * lh - 0.20
    cap_y = card_bot - 0.42
    ylim_bot = cap_y - 0.30
    figh = (5.8 - ylim_bot) * IPU

    fig, ax = plt.subplots(figsize=(figw, figh))
    ax.set_xlim(0, 10); ax.set_ylim(ylim_bot, 5.8); ax.axis("off")
    ax.text(5, 5.60, "Complying and failing both happen for structural reasons",
            ha="center", va="top", fontsize=17, weight="bold")

    for k, im in enumerate(DONE):
        q1 = im["q1"]
        col = GREEN if q1["answer"] == "YES" else RED
        x0 = 0.3 + k * w
        cx = x0 + (w - 0.24) / 2
        ax.add_patch(FancyBboxPatch((x0, card_bot), w - 0.24, 4.60 - card_bot,
                                    boxstyle="round,pad=0.05,rounding_size=0.14",
                                    linewidth=1.6, edgecolor=col,
                                    facecolor="white", zorder=1))
        ax.text(cx, 4.35, im["name"], ha="center",
                fontsize=14.5, weight="bold", zorder=3)
        # path_model has no reliable separator -- ngtcp2's carries no semicolon
        # at all, so .split(';')[0] returned the whole sentence and it ran clear
        # across three neighbouring cards. Wrap to the card instead.
        ax.text(cx, 4.06,
                wrap_to(f"{im['language']} · {im['path_model']}", card_in * 0.92,
                        8.5, max_lines=2),
                ha="center", va="top", fontsize=8.5, color=MUTE, zorder=3,
                linespacing=1.3)
        # ASYMMETRIC is 10 characters where YES is 3; at a fixed 26pt it was far
        # wider than its card and overlapped both neighbours.
        ax.text(cx, 3.28, q1["answer"], ha="center", va="center",
                fontsize=fit_fontsize(q1["answer"], card_in * 0.86, 26,
                                      floor=12, bold=True),
                weight="bold", color=col, zorder=3)
        ax.text(cx, MECH_TOP, mech[im["name"]], ha="center", va="top",
                fontsize=MECH_FS, zorder=3, linespacing=MECH_LS)

    # Accurate statement: quic-go DOES comply via its purpose-built handler, so
    # "the named mechanism never produces the result" would be false. The true
    # claim is that no two of them get there the same way.
    # Was hardcoded "Three implementations, three different mechanisms" and stayed
    # that way as the survey grew to five -- contradicting the slide title above
    # it. Count both from the data so it cannot drift again.
    n_dead = sum(1 for im in DONE if (im.get("reset_hook") or {}).get("dead"))
    n_mech = len({im["q1"].get("mechanism", "") for im in DONE})
    ax.text(5, cap_y,
            f"{len(DONE)} implementations, {n_mech} different mechanisms — "
            f"and in {n_dead} of them the hook named for the job is never called.",
            ha="center", fontsize=12.5, weight="bold")
    fig.tight_layout()
    fig.savefig(f"{FIG}/p2_fig3_mechanisms.png", dpi=175)
    plt.close(fig)
    print("wrote p2_fig3_mechanisms.png")


# ------------------------------------------------------------------ figure 4
def fig_cwnd_evidence():
    """The measured evidence: what the window does at the switch."""
    have = [im for im in DONE if im.get("live") and im["live"].get("cwnd_before_bytes")]
    if not have:
        print("SKIP p2_fig4 (no live data)")
        return
    fig, ax = plt.subplots(figsize=(11.0, 5.8))
    xs = range(len(have))
    width = 0.38
    for k, im in enumerate(have):
        lv = im["live"]
        before = lv["cwnd_before_bytes"] / 1024
        after = lv["cwnd_after_bytes"] / 1024
        ax.bar(k - width / 2, before, width, color=BLUE, zorder=3)
        ax.bar(k + width / 2, after, width,
               color=GREEN if lv.get("reset_observed") else RED, zorder=3)
        ax.text(k - width / 2, before + 8, f"{before:,.0f}", ha="center",
                fontsize=10.5, weight="bold")
        ax.text(k + width / 2, after + 8, f"{after:,.0f}", ha="center",
                fontsize=10.5, weight="bold")
        iw = im.get("initial_cwnd_bytes")
        if iw:
            ax.plot([k - 0.46, k + 0.46], [iw / 1024] * 2, ls="--", lw=1.5,
                    color=INK, zorder=4)
    ax.set_xticks(list(xs))
    # n= used to be drawn at y=-46 in DATA coordinates, which put it exactly
    # where the tick labels sit -- it struck through every implementation name.
    # Fold it into the tick label so the two can never collide.
    ax.set_xticklabels(
        [f"{im['name']}\nn={im['live'].get('reps', '?')}" for im in have],
        fontsize=13)
    ax.set_ylabel("congestion window (KB)")
    ax.set_title("What the send-rate setting does at the network switch",
                 fontsize=16, weight="bold", pad=14)
    ax.grid(axis="y", alpha=.22, zorder=0)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    from matplotlib.patches import Patch
    ax.legend(handles=[
        Patch(facecolor=BLUE, label="just before the switch"),
        Patch(facecolor=GREEN, label="just after — reset to the initial window"),
        Patch(facecolor=RED, label="just after — unchanged (no reset)"),
    ], frameon=False, fontsize=10.5, loc="upper center", ncol=3,
        bbox_to_anchor=(0.5, -0.17))   # tick labels are two lines now (name + n=)
    # Headroom for the note: without it the tallest bar's value label (msquic at
    # 1,450 KB) rendered straight through this line.
    tallest = max(im["live"]["cwnd_before_bytes"] / 1024 for im in have)
    ax.set_ylim(0, tallest * 1.22)
    ax.text(0.5, 0.955, "dashed line = each implementation's own initial window",
            transform=ax.transAxes, ha="center", fontsize=10, color=MUTE)
    fig.tight_layout()
    fig.savefig(f"{FIG}/p2_fig4_cwnd_evidence.png", dpi=175, bbox_inches="tight")
    plt.close(fig)
    print("wrote p2_fig4_cwnd_evidence.png")


if __name__ == "__main__":
    fig_compliance_table()
    fig_dead_hooks()
    fig_mechanisms()
    fig_cwnd_evidence()
    print(f"\n{len(DONE)}/{len(IMPLS)} implementations audited; figures in {FIG}")
