#!/usr/bin/env python3
"""parse_qlog.py -- extract congestion/RTT time series and migration events
from a picoquic qlog (draft-00) into tidy CSV.

Used for the PV-Seed baseline characterization: the SERVER qlog is the
scientifically relevant one for a download, because the server is the data
sender and therefore the endpoint whose congestion controller governs
throughput.

Usage:
    parse_qlog.py --qlog FILE.qlog [--label KEY=VAL ...] [--csv OUT.csv]
                  [--summary]

Emits one row per recovery/metrics_updated sample:
    <labels...>, time_us, cwnd, bytes_in_flight, smoothed_rtt, min_rtt, latest_rtt

--summary prints the migration window (first/last path_challenge or
path_response frame), cwnd immediately before it, the minimum cwnd inside and
shortly after it, and packet-loss counts -- i.e. the evidence needed to say
whether an RFC 9000 s9.4 congestion reset actually occurred.
"""
import argparse
import csv
import json
import sys

# RFC 9002 s7.2 initial window as picoquic defines it:
# PICOQUIC_CWIN_INITIAL = 10 * PICOQUIC_MAX_PACKET_SIZE (1536) = 15360
PICOQUIC_CWIN_INITIAL = 15360

# picoquic sizes its windows from the NEGOTIATED path MTU, not from the 1536
# constant. On this testbed the send size is 1424 B, so the effective initial
# window is 14,240 B and the effective floor (PICOQUIC_CWIN_MINIMUM = 2 x MTU)
# is 2,848 B. Both are accepted as reset-shaped values.
PICOQUIC_EFFECTIVE_MTU = 1424
CWIN_RESET_CANDIDATES = (PICOQUIC_CWIN_INITIAL, 10 * PICOQUIC_EFFECTIVE_MTU)
CWIN_FLOOR = 2 * PICOQUIC_EFFECTIVE_MTU


def load_trace(path):
    with open(path) as f:
        doc = json.load(f)
    trace = doc["traces"][0]
    fields = trace["event_fields"]
    idx = {name: fields.index(name) for name in ("relative_time", "category", "event", "data")}
    return trace, idx


def extract(trace, idx):
    ti, ci, ei, di = idx["relative_time"], idx["category"], idx["event"], idx["data"]
    metrics, path_events, losses, sent_bytes = [], [], [], []

    for ev in trace["events"]:
        t, cat, name, data = ev[ti], ev[ci], ev[ei], ev[di]
        if not isinstance(data, dict):
            continue

        if name == "metrics_updated" and "cwnd" in data:
            metrics.append({
                "time_us": t,
                "cwnd": data.get("cwnd"),
                "bytes_in_flight": data.get("bytes_in_flight"),
                "smoothed_rtt": data.get("smoothed_rtt"),
                "min_rtt": data.get("min_rtt"),
                "latest_rtt": data.get("latest_rtt"),
            })
        elif name in ("packet_sent", "packet_received"):
            for fr in data.get("frames") or []:
                ft = fr.get("frame_type", "")
                if ft.startswith("path_"):
                    path_events.append({"time_us": t, "event": name, "frame": ft})
        elif name == "packet_lost":
            losses.append({"time_us": t, "trigger": data.get("trigger")})
        elif name == "datagram_sent" and "byte_length" in data:
            # PV-Seed (Task C): raw bytes actually put on the wire by this
            # endpoint, used for throughput/recovery-time derivation in
            # build_baseline_dataset.py. Kept as a separate list (not folded
            # into `metrics`) because datagram_sent events are far more
            # frequent than metrics_updated samples and are on their own
            # independent time base.
            sent_bytes.append({"time_us": t, "byte_length": data["byte_length"]})

    return metrics, path_events, losses, sent_bytes


def summarize(metrics, path_events, losses, label=""):
    print(f"\n===== {label} =====")
    if not path_events:
        print("  no path_challenge/path_response frames found -- no migration detected")
        return
    t0 = min(p["time_us"] for p in path_events)
    t1 = max(p["time_us"] for p in path_events)
    print(f"  migration window : t={t0} .. {t1} us  ({len(path_events)} path_* frame events)")

    before = [m for m in metrics if m["time_us"] < t0]
    during = [m for m in metrics if t0 <= m["time_us"] <= t1]
    after1 = [m for m in metrics if t1 < m["time_us"] <= t1 + 1_000_000]

    if before:
        b = before[-1]
        print(f"  cwnd BEFORE      : {b['cwnd']:>9,} B   (srtt {b['smoothed_rtt']} us)")
    pool = during + after1
    if pool:
        mn = min(pool, key=lambda m: m["cwnd"])
        print(f"  cwnd MIN in/after: {mn['cwnd']:>9,} B   at t={mn['time_us']} us")
        ratio = mn["cwnd"] / PICOQUIC_CWIN_INITIAL
        print(f"  vs CWIN_INITIAL  : {PICOQUIC_CWIN_INITIAL:,} B  ->  min is {ratio:.1f}x initial")

        # The reset-versus-loss discriminator, applied here rather than by eye.
        #
        # This test used to be `min_cwnd <= INITIAL * 1.05`, i.e. "at or BELOW
        # the initial window", and reported a reset. That is wrong, and it was
        # latent until a run at 20 Mbit made the loss cascade deep enough to
        # reach the floor: a window BELOW the initial value cannot have been set
        # BY a reset, because a reset assigns the initial value exactly. Falling
        # below it is the signature of a loss cascade bottoming out at
        # PICOQUIC_CWIN_MINIMUM. Require an exact hit instead, and say which of
        # the two happened.
        hits = [m for m in pool
                if any(abs(m["cwnd"] - c) <= 1 for c in CWIN_RESET_CANDIDATES)]
        cand = " or ".join(f"{c:,}" for c in CWIN_RESET_CANDIDATES)
        if hits:
            print(f"  VERDICT          : RESET OCCURRED -- {len(hits)} sample(s) land exactly "
                  f"on the initial window ({cand} B)")
        elif mn["cwnd"] < min(CWIN_RESET_CANDIDATES):
            print(f"  VERDICT          : NO RESET -- window fell BELOW the initial window "
                  f"({cand} B) without ever taking it; that is a loss cascade toward the "
                  f"{CWIN_FLOOR:,} B floor, not a reset")
            if abs(mn["cwnd"] - CWIN_FLOOR) <= 1:
                print(f"                     (it reached the floor exactly: "
                      f"2 x {PICOQUIC_EFFECTIVE_MTU} = {CWIN_FLOOR:,} B)")
        else:
            print("  VERDICT          : NO RESET (cwnd never approached the initial window)")

    if after1:
        srtts = [m["smoothed_rtt"] for m in after1 if m["smoothed_rtt"]]
        if srtts:
            print(f"  srtt after (max) : {max(srtts)} us   (PICOQUIC_INITIAL_RTT = 250000 us)")
    win_loss = [l for l in losses if t0 - 500_000 <= l["time_us"] <= t1 + 1_000_000]
    print(f"  packets lost near migration (+-): {len(win_loss)}")
    print(f"  total packets lost in trace     : {len(losses)}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--qlog", required=True)
    ap.add_argument("--label", action="append", default=[],
                    help="extra CSV columns as KEY=VAL (repeatable)")
    ap.add_argument("--csv")
    ap.add_argument("--summary", action="store_true")
    args = ap.parse_args()

    labels = {}
    for kv in args.label:
        if "=" not in kv:
            sys.exit(f"--label must be KEY=VAL, got {kv!r}")
        k, v = kv.split("=", 1)
        labels[k] = v

    trace, idx = load_trace(args.qlog)
    metrics, path_events, losses, sent_bytes = extract(trace, idx)

    if args.csv:
        cols = list(labels) + ["time_us", "cwnd", "bytes_in_flight",
                               "smoothed_rtt", "min_rtt", "latest_rtt"]
        with open(args.csv, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=cols)
            w.writeheader()
            for m in metrics:
                w.writerow({**labels, **m})
        print(f"wrote {len(metrics)} rows -> {args.csv}", file=sys.stderr)

    if args.summary:
        summarize(metrics, path_events, losses,
                  label=labels.get("arm", args.qlog.split("/")[-1]))


if __name__ == "__main__":
    main()
