#!/usr/bin/env python3
"""parse_qlog_quiche.py -- extract congestion/RTT time series and migration
events from a quiche (Cloudflare, Rust) qlog into the SAME tidy CSV schema
that parse_qlog.py (picoquic) and parse_qlog_quicgo.py (quic-go) produce:

    <labels...>, time_us, cwnd, bytes_in_flight, smoothed_rtt, min_rtt, latest_rtt

PV-Seed Phase 2 (quiche survey, subject 3). This is a THIRD, separate
parser -- not a flag on the other two -- because quiche's qlog, while also
JSON-SEQ serialized like quic-go's (RFC 7464 JSON Text Sequences: each
record preceded by a 0x1E byte; first record is a {"file_schema":...}
header; every subsequent record is a standalone event object), uses a
DIFFERENT event-category prefix than quic-go:

  quic-go (.sqlog): event names are "transport:packet_sent",
                     "transport:packet_received", "recovery:metrics_updated",
                     "recovery:packet_lost" -- category and event joined by
                     ':', with category drawn from {transport, recovery, ...}.
                     Schema urn:ietf:params:qlog:events:quic-12.

  quiche  (.sqlog): quiche/qlog/src/events/mod.rs's `EventData` enum tags
                     EVERY QUIC-layer event under a single "quic:" prefix
                     regardless of the picoquic/quic-go transport/recovery
                     split, e.g. "quic:packet_sent", "quic:packet_received",
                     "quic:recovery_metrics_updated", "quic:packet_lost"
                     (qlog/src/events/mod.rs lines ~437, 473-539). Also
                     schema urn:ietf:params:qlog:events:quic-12 (same draft
                     version as quic-go), and RTT/time fields are likewise
                     milliseconds (f32), converted here the same way.

Verified against quiche/qlog/src/events/quic.rs (`RecoveryMetricsUpdated`,
`QuicFrame` with `#[serde(tag = "frame_type")] #[serde(rename_all =
"snake_case")]` -- PathChallenge/PathResponse frames serialize as
"path_challenge"/"path_response", same prefix convention the other two
parsers already filter on) and quiche/quiche/src/recovery/mod.rs
(`latest.min_rtt.as_secs_f32() * 1000.0` -- confirms ms units).

Usage:
    parse_qlog_quiche.py --qlog FILE.sqlog [--label KEY=VAL ...] [--csv OUT.csv]
                         [--summary]
"""
import argparse
import csv
import json
import sys

RECORD_SEPARATOR = 0x1E

# quiche/quiche/src/lib.rs:
#   const MAX_SEND_UDP_PAYLOAD_SIZE: usize = 1200;              (line ~464)
#   const DEFAULT_INITIAL_CONGESTION_WINDOW_PACKETS: usize = 10; (line ~496)
# quiche/quiche/src/recovery/congestion/mod.rs Congestion::from_config():
#   initial_congestion_window =
#       recovery_config.max_send_udp_payload_size
#       * recovery_config.initial_congestion_window_packets
# The PV-Seed harness (harness/quiche/) deliberately does NOT override either
# value (library defaults throughout), unlike quiche's own demo apps (which
# hardcode MAX_DATAGRAM_SIZE = 1350) -- see harness/quiche/src/bin/qcserver.rs.
QUICHE_CWIN_INITIAL = 1200 * 10  # = 12000 bytes, PV-Seed harness config

# quiche/quiche/src/recovery/mod.rs: const MINIMUM_WINDOW_PACKETS: usize = 2;
QUICHE_CWIN_MINIMUM = 1200 * 2  # = 2400 bytes, congestion-window floor

# quiche/quiche/src/recovery/congestion/cubic.rs: const BETA_CUBIC: f64 = 0.7;
# (RFC 9438 CUBIC multiplicative-decrease factor; quiche's default
# cc_algorithm is CUBIC -- CongestionControlAlgorithm::CUBIC, lib.rs ~654).
QUICHE_CUBIC_BETA = 0.7


def load_records(path):
    """Split a qlog JSON-SEQ file on RS bytes and json.loads each piece.
    Returns (header, events) where header is the first record (dict with
    'file_schema') and events is a list of {'time','name','data',...} dicts.
    """
    with open(path, "rb") as f:
        raw = f.read()
    chunks = raw.split(bytes([RECORD_SEPARATOR]))
    records = []
    for chunk in chunks:
        chunk = chunk.strip()
        if not chunk:
            continue
        records.append(json.loads(chunk))
    if not records:
        raise ValueError(f"{path}: no JSON-SEQ records found (empty or wrong format?)")
    header = records[0]
    if "file_schema" not in header:
        raise ValueError(f"{path}: first record is not a qlog JSON-SEQ header "
                          f"(no 'file_schema' key) -- got keys {list(header.keys())}")
    events = records[1:]
    return header, events


def extract(events):
    metrics, path_events, losses, sent_bytes = [], [], [], []

    for ev in events:
        t_ms = ev.get("time")
        name = ev.get("name")
        data = ev.get("data")
        if t_ms is None or not isinstance(data, dict):
            continue
        t_us = t_ms * 1000.0  # ms -> us, to match picoquic's relative_time units

        if name == "quic:recovery_metrics_updated":
            if not any(k in data for k in ("congestion_window", "bytes_in_flight",
                                            "smoothed_rtt", "min_rtt", "latest_rtt")):
                continue
            metrics.append({
                "time_us": t_us,
                "cwnd": data.get("congestion_window"),
                "bytes_in_flight": data.get("bytes_in_flight"),
                # qlog-12 RTT fields are milliseconds (float); convert to
                # microseconds (int, rounded) to match picoquic's CSV units.
                "smoothed_rtt": round(data["smoothed_rtt"] * 1000) if data.get("smoothed_rtt") is not None else None,
                "min_rtt": round(data["min_rtt"] * 1000) if data.get("min_rtt") is not None else None,
                "latest_rtt": round(data["latest_rtt"] * 1000) if data.get("latest_rtt") is not None else None,
            })
        elif name in ("quic:packet_sent", "quic:packet_received"):
            for fr in data.get("frames") or []:
                ft = fr.get("frame_type", "")
                if ft.startswith("path_"):
                    path_events.append({"time_us": t_us, "event": name, "frame": ft})
        elif name == "quic:packet_lost":
            losses.append({"time_us": t_us, "trigger": data.get("trigger")})

    return metrics, path_events, losses, sent_bytes


def summarize(metrics, path_events, losses, label=""):
    print(f"\n===== {label} =====")
    if not path_events:
        print("  no path_challenge/path_response frames found -- no migration detected")
        return
    t0 = min(p["time_us"] for p in path_events)
    t1 = max(p["time_us"] for p in path_events)
    print(f"  migration window : t={t0:.0f} .. {t1:.0f} us  ({len(path_events)} path_* frame events)")

    before = [m for m in metrics if m["time_us"] < t0]
    during = [m for m in metrics if t0 <= m["time_us"] <= t1]
    after1 = [m for m in metrics if t1 < m["time_us"] <= t1 + 1_000_000]

    pre_cwnd = None
    if before:
        b = before[-1]
        pre_cwnd = b["cwnd"]
        cwnd_str = f"{b['cwnd']:>9,}" if b['cwnd'] is not None else "      n/a"
        print(f"  cwnd BEFORE      : {cwnd_str} B   (srtt {b['smoothed_rtt']} us)")
    pool = [m for m in (during + after1) if m["cwnd"] is not None]
    if pool:
        mn = min(pool, key=lambda m: m["cwnd"])
        print(f"  cwnd MIN in/after: {mn['cwnd']:>9,} B   at t={mn['time_us']:.0f} us")
        ratio = mn["cwnd"] / QUICHE_CWIN_INITIAL
        print(f"  vs CWIN_INITIAL  : {QUICHE_CWIN_INITIAL:,} B  ->  min is {ratio:.2f}x initial")
        if mn["cwnd"] <= QUICHE_CWIN_INITIAL * 1.05:
            print("  VERDICT (cwnd)   : RESET-CONSISTENT (cwnd reached the initial window)")
        else:
            print("  VERDICT (cwnd)   : NO RESET (cwnd never approached the initial window)")

        # Reset-vs-loss discriminator (mirrors the quic-go analysis): can a
        # pure multiplicative-decrease loss event from the pre-migration cwnd
        # explain the observed post-migration minimum?
        if pre_cwnd is not None:
            loss_cwnd = int(pre_cwnd * QUICHE_CUBIC_BETA)
            print(f"  loss-only would give: {loss_cwnd:,} B (pre_cwnd * BETA_CUBIC {QUICHE_CUBIC_BETA})"
                  f"  [floor {QUICHE_CWIN_MINIMUM:,} B]")
            explainable_by_loss = (
                abs(mn["cwnd"] - loss_cwnd) <= 1 or
                mn["cwnd"] <= QUICHE_CWIN_MINIMUM + 1
            )
            if mn["cwnd"] <= QUICHE_CWIN_INITIAL * 1.05 and not explainable_by_loss:
                print("  DISCRIMINATOR    : observed value matches CWIN_INITIAL and does NOT match "
                      "a loss-only multiplicative decrease or the min-window floor -> RESET, not loss")

    if after1:
        srtts = [m["smoothed_rtt"] for m in after1 if m["smoothed_rtt"]]
        if srtts:
            print(f"  srtt after (max) : {max(srtts)} us   (quiche DEFAULT_INITIAL_RTT = 333000 us)")
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

    header, events = load_records(args.qlog)
    metrics, path_events, losses, sent_bytes = extract(events)

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
