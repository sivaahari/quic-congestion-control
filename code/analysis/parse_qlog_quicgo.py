#!/usr/bin/env python3
"""parse_qlog_quicgo.py -- extract congestion/RTT time series and migration
events from a quic-go qlog into the SAME tidy CSV schema that
parse_qlog.py produces for picoquic:

    <labels...>, time_us, cwnd, bytes_in_flight, smoothed_rtt, min_rtt, latest_rtt

PV-Seed Phase 2 (quic-go survey). This is a SEPARATE parser, not a flag on
parse_qlog.py, because quic-go's qlog is a fundamentally different
serialization from picoquic's:

  picoquic (.qlog):  one JSON document, {"traces":[{"event_fields":[...],
                      "events":[[...],[...]]}]} -- events are POSITIONAL
                      arrays indexed via event_fields. relative_time in
                      MICROSECONDS (int).

  quic-go   (.sqlog): qlog "JSON-SEQ" serialization
                      (draft-ietf-quic-qlog-main-schema-12): the file is a
                      sequence of RFC-7464 JSON Text Sequences (each JSON
                      text preceded by a 0x1E record-separator byte). The
                      FIRST record is a header ({"file_schema":...,
                      "trace":{...}}); every subsequent record is a
                      standalone event object {"time": <ms, float,
                      relative to the header's reference_time>, "name":
                      "<category>:<event>", "data": {...}}. RTT fields in
                      the "recovery:metrics_updated" event are in
                      MILLISECONDS (float), congestion_window /
                      bytes_in_flight are named exactly as in picoquic's
                      output but are qlog-schema-12 field names occurring
                      inside a "data" object rather than a positional
                      array.

This parser normalizes quic-go's ms-based fields to the SAME microsecond
integer units parse_qlog.py emits, so a downstream harness can treat both
CSVs identically without knowing which implementation produced them.

Usage:
    parse_qlog_quicgo.py --qlog FILE.sqlog [--label KEY=VAL ...] [--csv OUT.csv]
                         [--summary]
"""
import argparse
import csv
import json
import sys

RECORD_SEPARATOR = 0x1E

# quic-go internal/congestion/cubic_sender.go:
#   initialCongestionWindow = 32 (packets)
#   NewCubicSender(...) -> initialCongestionWindow * initialMaxDatagramSize
# internal/protocol/params.go: InitialPacketSize = 1280
# (the default used by our harness -- we do not override quic.Config.InitialPacketSize)
QUICGO_CWIN_INITIAL = 32 * 1280  # = 40960 bytes, default config


def load_records(path):
    """Split a qlog JSON-SEQ file on RS bytes and json.loads each piece.
    Returns (header, events) where header is the first record (dict with
    'file_schema') and events is a list of {'time','name','data'} dicts.
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

        if name == "recovery:metrics_updated":
            # PTOCountUpdated also uses this event name but only carries
            # pto_count; skip records with none of the metrics we track.
            if not any(k in data for k in ("congestion_window", "bytes_in_flight",
                                            "smoothed_rtt", "min_rtt", "latest_rtt")):
                continue
            metrics.append({
                "time_us": t_us,
                "cwnd": data.get("congestion_window"),
                "bytes_in_flight": data.get("bytes_in_flight"),
                # qlog-12 RTT fields are milliseconds (float); convert to
                # microseconds (int, rounded) to match picoquic's CSV units.
                "smoothed_rtt": round(data["smoothed_rtt"] * 1000) if "smoothed_rtt" in data else None,
                "min_rtt": round(data["min_rtt"] * 1000) if "min_rtt" in data else None,
                "latest_rtt": round(data["latest_rtt"] * 1000) if "latest_rtt" in data else None,
            })
        elif name in ("transport:packet_sent", "transport:packet_received"):
            for fr in data.get("frames") or []:
                ft = fr.get("frame_type", "")
                if ft.startswith("path_"):
                    path_events.append({"time_us": t_us, "event": name, "frame": ft})
        elif name == "recovery:packet_lost":
            losses.append({"time_us": t_us, "trigger": data.get("trigger")})
        elif name == "transport:packet_sent":
            # quic-go does not emit a separate datagram_sent event; byte_length
            # of the packet is under data.header / data.raw depending on
            # schema version. Left as a placeholder for parity with
            # parse_qlog.py's sent_bytes list; not populated here because our
            # summarize() below does not use it (throughput comes from the
            # harness's own byte counters, which are unambiguous).
            pass

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

    if before:
        b = before[-1]
        cwnd_str = f"{b['cwnd']:>9,}" if b['cwnd'] is not None else "      n/a"
        print(f"  cwnd BEFORE      : {cwnd_str} B   (srtt {b['smoothed_rtt']} us)")
    pool = [m for m in (during + after1) if m["cwnd"] is not None]
    if pool:
        mn = min(pool, key=lambda m: m["cwnd"])
        print(f"  cwnd MIN in/after: {mn['cwnd']:>9,} B   at t={mn['time_us']:.0f} us")
        ratio = mn["cwnd"] / QUICGO_CWIN_INITIAL
        print(f"  vs CWIN_INITIAL  : {QUICGO_CWIN_INITIAL:,} B  ->  min is {ratio:.2f}x initial")
        if mn["cwnd"] <= QUICGO_CWIN_INITIAL * 1.05:
            print("  VERDICT          : RESET OCCURRED (cwnd reached the initial window)")
        else:
            print("  VERDICT          : NO RESET (cwnd never approached the initial window)")

    if after1:
        srtts = [m["smoothed_rtt"] for m in after1 if m["smoothed_rtt"]]
        if srtts:
            print(f"  srtt after (max) : {max(srtts)} us   (quic-go DefaultInitialRTT = 100000 us)")
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
