#!/usr/bin/env python3
"""parse_qlog_msquic.py -- extract congestion/RTT time series and migration
events from an msquic survey harness log into the SAME tidy CSV schema
parse_qlog.py/parse_qlog_quicgo.py/parse_qlog_quiche.py produce:

    <labels...>, time_us, cwnd, bytes_in_flight, smoothed_rtt, min_rtt, latest_rtt

NAMING NOTE: unlike the other three parsers, the input here is NOT a qlog
file. msquic has no native qlog output on Linux (see the task report's
"KNOWN RISK -- instrumentation" section) -- this harness instead polls
QUIC_PARAM_CONN_STATISTICS_V2 (QUIC_STATISTICS_V2.SendCongestionWindow/Rtt/
MinRtt) from a background thread in harness/msquic/{client,server}.cpp and
prints one STATS line per sample to the process's own stdout, e.g.:

    [mq_server] t_us=547867 STATS cwnd=477718 srtt_us=1265 min_rtt_us=596 \\
        max_rtt_us=2007 rtt_var_us=369 cc_events=0 persistent_cc_events=0 \\
        send_total_bytes=539206 send_stream_bytes=524288 send_mtu=1500

msquic itself is built with -DQUIC_LOGGING_TYPE=stdout (see
_build/msquic_configure_build.sh), so its OWN internal QuicTraceEvent/
QuicTraceLog* calls ALSO land on the same stdout stream, interleaved with
our STATS/MARKER lines -- e.g. the line that directly confirms or refutes
the source-level "UdpPortChangeOnly" finding:

    [conn][%p] Path[%hhu] Set active (rebind=%hhu)

This file is kept named parse_qlog_*_msquic.py to match the survey's
one-parser-per-implementation / one-shared-CSV-schema convention (per the
task instructions), even though "qlog" is a misnomer for this input.

CAVEAT (documented, not hidden): msquic's own internal trace lines carry NO
per-line timestamp in QUIC_LOGGING_TYPE=stdout mode (confirmed by direct
inspection: the QuicTraceEvent format strings for e.g. ConnPathActine/
ConnCongestionV2 have no time placeholder, and observed output has none).
Because both our own timestamped lines and msquic's own untimestamped lines
are written to the SAME process's stdout in real chronological order, this
parser attributes each untimestamped internal-trace line the most recently
seen t_us value from OUR lines above it in the file (bounded by
--stats-interval-ms, default 5ms in the migrate-demo scenario) -- i.e. an
approximation accurate to within one polling interval, not exact.

Usage:
    parse_qlog_msquic.py --log FILE.log [--label KEY=VAL ...] [--csv OUT.csv]
                         [--summary]
"""
import argparse
import csv
import re
import sys

# RFC 9002 s7.2 initial window as msquic defines it:
# QUIC_INITIAL_WINDOW_PACKETS (src/core/quicdef.h) = 10
# CongestionWindow = InitialWindowPackets * DatagramPayloadLength
# DatagramPayloadLength is ~1220-1252B before path MTU discovery raises it to
# up to SendMtu (1500 in this survey's testbed, MTU 1500 throughout). So the
# initial window is NOT a single constant -- it depends on the datagram
# payload size in effect AT THE TIME OF THE RESET, same caveat as the other
# three implementations' MTU-dependent constants. Observed directly in this
# survey's own loopback smoke test: cwnd=12200 = 10 * 1220 at connection
# start (before MTU discovery); testbed/scenarios/msquic_migrate_demo.sh
# runs over MTU-1500 veths, so post-MTU-discovery IW = 10*1500 = 15000.
MSQUIC_INITIAL_WINDOW_PACKETS = 10
# RFC 9002-style persistent congestion floor, src/core/quicdef.h:
# QUIC_PERSISTENT_CONGESTION_WINDOW_PACKETS = 2
MSQUIC_PERSISTENT_CONGESTION_WINDOW_PACKETS = 2
# Cubic multiplicative decrease on an ordinary (non-persistent) congestion
# event, src/core/cubic.c: TEN_TIMES_BETA_CUBIC = 7 -> beta = 0.7
MSQUIC_CUBIC_BETA = 0.7

STATS_RE = re.compile(
    r"^\[(?P<role>mq_server|mq_client)\] t_us=(?P<t_us>\d+) STATS "
    r"cwnd=(?P<cwnd>\d+) srtt_us=(?P<srtt>\d+) min_rtt_us=(?P<min_rtt>\d+) "
    r"max_rtt_us=(?P<max_rtt>\d+) rtt_var_us=(?P<rtt_var>\d+) "
    r"cc_events=(?P<cc_events>\d+) persistent_cc_events=(?P<pcc_events>\d+) "
    r"send_total_bytes=(?P<send_total>\d+) send_stream_bytes=(?P<send_stream>\d+) "
    r"send_mtu=(?P<mtu>\d+)"
)
MARKER_RE = re.compile(r"^\[(?P<role>mq_server|mq_client)\] t_us=(?P<t_us>\d+) (?P<rest>.+)$")
REBIND_RE = re.compile(r"Path\[\d+\] Set active \(rebind=(?P<rebind>\d)\)")
CONGESTION_EVENT_RE = re.compile(r"Congestion event: IsEcn=(?P<ecn>\d)")
PERSISTENT_CONGESTION_RE = re.compile(r"Persistent congestion event")
CONNSTATS_RE = re.compile(
    r"STATS: SRtt=(?P<srtt>\d+) CongestionCount=(?P<cc>\d+) "
    r"PersistentCongestionCount=(?P<pcc>\d+) SendTotalBytes=(?P<stb>\d+) "
    r"RecvTotalBytes=(?P<rtb>\d+) CongestionWindow=(?P<cwnd>\d+) Cc=(?P<cc_algo>\w+)"
)

# Markers this harness itself prints (see harness/msquic/{client,server}.cpp).
CLIENT_TRIGGER = "MIGRATE_TRIGGER"
CLIENT_CUTOVER = "MIGRATE_CUTOVER_CONFIRMED"
CLIENT_CUTOVER_EVENT = "MIGRATE_LOCAL_ADDR_CHANGED_EVENT"
SERVER_PEER_CHANGED = "SERVER_PEER_ADDR_CHANGED"


def extract(lines):
    metrics = []
    markers = []          # our own MARKER lines (not STATS)
    rebind_events = []    # (approx_t_us, rebind_flag) from internal trace
    congestion_events = []  # (approx_t_us, kind) ordinary/persistent
    connstats_lines = []  # (approx_t_us, dict) final STATS: summary lines

    last_t_us = 0
    for raw in lines:
        line = raw.rstrip("\n")

        m = STATS_RE.match(line)
        if m:
            t_us = int(m.group("t_us"))
            last_t_us = t_us
            metrics.append({
                "role": m.group("role"),
                "time_us": t_us,
                "cwnd": int(m.group("cwnd")),
                "bytes_in_flight": None,  # not exposed by QUIC_STATISTICS_V2; see module docstring
                "smoothed_rtt": int(m.group("srtt")),
                "min_rtt": int(m.group("min_rtt")),
                "latest_rtt": None,       # V2 has no distinct "latest sample" field; see docstring
                "max_rtt": int(m.group("max_rtt")),
                "cc_events": int(m.group("cc_events")),
                "persistent_cc_events": int(m.group("pcc_events")),
            })
            continue

        m = MARKER_RE.match(line)
        if m:
            t_us = int(m.group("t_us"))
            last_t_us = t_us
            markers.append({"role": m.group("role"), "time_us": t_us, "text": m.group("rest")})
            continue

        m = REBIND_RE.search(line)
        if m:
            rebind_events.append((last_t_us, int(m.group("rebind"))))
            continue

        if PERSISTENT_CONGESTION_RE.search(line):
            congestion_events.append((last_t_us, "persistent"))
            continue

        m = CONGESTION_EVENT_RE.search(line)
        if m:
            congestion_events.append((last_t_us, "ecn" if m.group("ecn") == "1" else "ordinary"))
            continue

        m = CONNSTATS_RE.search(line)
        if m:
            connstats_lines.append((last_t_us, m.groupdict()))
            continue

    return metrics, markers, rebind_events, congestion_events, connstats_lines


def summarize(metrics, markers, rebind_events, congestion_events, connstats_lines, label=""):
    print(f"\n===== {label} =====")

    trigger = next((m for m in markers if CLIENT_TRIGGER in m["text"]), None)
    cutover = next((m for m in markers if CLIENT_CUTOVER in m["text"] and "TIMEOUT" not in m["text"]
                     and "ABANDONED" not in m["text"]), None)
    peer_changed = [m for m in markers if SERVER_PEER_CHANGED in m["text"]]

    if not trigger and not peer_changed:
        print("  no MIGRATE_TRIGGER (client) or SERVER_PEER_ADDR_CHANGED (server) marker found "
              "-- no migration detected in this log")
        return

    if trigger and cutover:
        t0, t1 = trigger["time_us"], cutover["time_us"]
        print(f"  [client] migration window : t={t0} .. {t1} us "
              f"(trigger -> confirmed cutover, {(t1 - t0) / 1000:.1f} ms)")
    elif peer_changed:
        t0 = t1 = peer_changed[0]["time_us"]
        print(f"  [server] peer address change observed at t={t0} us")
    else:
        t0 = t1 = trigger["time_us"] if trigger else 0
        print(f"  migration triggered at t={t0} us but no confirmed cutover found in this log")

    # --- THE empirical check for the source-level "UdpPortChangeOnly" finding ---
    if rebind_events:
        print("  Path 'Set active (rebind=N)' events (internal trace; N=1 means msquic classified "
              "this promotion as a PORT-ONLY change and did NOT reset congestion control, "
              "N=0 means it reset -- see src/core/path.c QuicPathSetActive in the task report):")
        for t, rebind in rebind_events:
            tag = "PORT-ONLY (CC NOT reset)" if rebind == 1 else "REAL CHANGE (CC reset)"
            print(f"    t~={t} us  rebind={rebind}  [{tag}]")
    else:
        print("  no 'Set active (rebind=N)' trace line found in this log")

    # IW/persistent-congestion-floor depend on the in-effect datagram payload
    # size (MTU discovery hasn't necessarily completed on a just-reset path),
    # so report against both the pre-discovery (1220B) and post-discovery
    # (1500B, this testbed's veth MTU) payload sizes rather than one constant.
    iw_1500, iw_1220 = MSQUIC_INITIAL_WINDOW_PACKETS * 1500, MSQUIC_INITIAL_WINDOW_PACKETS * 1220
    pc_1500, pc_1220 = (MSQUIC_PERSISTENT_CONGESTION_WINDOW_PACKETS * 1500,
                        MSQUIC_PERSISTENT_CONGESTION_WINDOW_PACKETS * 1220)
    print(f"  reference values : IW(mtu=1500)={iw_1500:,}B IW(mtu=1220,pre-discovery)={iw_1220:,}B  "
          f"persistent-cong-floor(mtu=1500)={pc_1500:,}B persistent-cong-floor(mtu=1220)={pc_1220:,}B  "
          f"ordinary-loss(x0.7) of pre-migration cwnd shown below")

    before = [m for m in metrics if m["time_us"] < t0]
    after = [m for m in metrics if m["time_us"] >= t0]
    if before:
        b = before[-1]
        print(f"  cwnd BEFORE      : {b['cwnd']:>9,} B   (srtt {b['smoothed_rtt']} us, role={b['role']}, "
              f"x0.7 ordinary-loss would give {b['cwnd'] * MSQUIC_CUBIC_BETA:,.0f} B)")
    # THE discriminator: the FIRST sample at/after the migration marker, NOT
    # the minimum over some wide post-migration window -- a wide window
    # conflates the reset itself with whatever independent congestion events
    # happen afterward during the new path's own slow start (frequently
    # several, see congestion_events above), which this survey's other three
    # parsers' narrower windows mostly avoid but is a real risk here given
    # this harness's coarser (polling-interval-bounded) time resolution.
    if after:
        immediate = after[0]
        print(f"  cwnd IMMEDIATELY AFTER marker (first sample at/after t0, role={immediate['role']}): "
              f"{immediate['cwnd']:>9,} B  srtt={immediate['smoothed_rtt']}us  min_rtt={immediate['min_rtt']}us  "
              f"at t={immediate['time_us']} us (+{immediate['time_us'] - t0} us after marker)")
        c = immediate["cwnd"]
        if c in (iw_1500, iw_1220) or (before and abs(c - iw_1220) <= 50):
            print(f"  VERDICT          : EXACT MATCH to initial window (IW) -- this can only be a RESET, "
                  f"not any loss reaction (0.7x of the pre-migration {before[-1]['cwnd']:,} B would be "
                  f"{before[-1]['cwnd'] * MSQUIC_CUBIC_BETA:,.0f} B, nowhere near IW)")
        elif c <= iw_1500 * 1.05:
            print("  VERDICT          : consistent with RESET to initial window (within 5% of IW@1500)")
        elif before and c <= before[-1]["cwnd"] * MSQUIC_CUBIC_BETA * 1.1:
            print("  VERDICT          : consistent with an ORDINARY LOSS reaction (~0.7x pre-migration cwnd), "
                  "NOT a migration reset")
        else:
            print("  VERDICT          : inconclusive from this single sample -- inspect the CSV directly")

        # Secondary, clearly-separated observation: what happens over the
        # following ~2s (frequently further decay from independent loss
        # during the new path's own slow start -- NOT part of the reset
        # itself; see congestion_events above for exact timestamps/counts).
        window = [m for m in after if m["time_us"] <= t0 + 2_000_000 and m["cwnd"] is not None]
        if len(window) > 1:
            mn = min(window, key=lambda m: m["cwnd"])
            if mn["time_us"] != immediate["time_us"]:
                print(f"  (secondary) cwnd MIN within 2s after marker: {mn['cwnd']:>9,} B at t={mn['time_us']} us "
                      f"-- if lower than the immediate post-marker value above, that further drop is from "
                      f"SUBSEQUENT independent congestion events (see the list above), not the reset itself")

    if congestion_events:
        print(f"  congestion events near/after migration: {len(congestion_events)} total in whole log")
        near = [c for c in congestion_events if t0 - 500_000 <= c[0] <= t0 + 2_000_000]
        for t, kind in near:
            print(f"    t~={t} us  kind={kind}")

    if connstats_lines:
        t, d = connstats_lines[-1]
        print(f"  final ConnStatsV3 (t~={t} us): SRtt={d['srtt']}us CongestionCount={d['cc']} "
              f"PersistentCongestionCount={d['pcc']} CongestionWindow={d['cwnd']} Cc={d['cc_algo']}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True, help="mq_server or mq_client combined stdout log")
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

    with open(args.log, "r", errors="replace") as f:
        lines = f.readlines()

    metrics, markers, rebind_events, congestion_events, connstats_lines = extract(lines)

    if args.csv:
        cols = list(labels) + ["time_us", "cwnd", "bytes_in_flight",
                               "smoothed_rtt", "min_rtt", "latest_rtt"]
        with open(args.csv, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=cols)
            w.writeheader()
            for m in metrics:
                row = {**labels,
                       "time_us": m["time_us"], "cwnd": m["cwnd"],
                       "bytes_in_flight": "", "smoothed_rtt": m["smoothed_rtt"],
                       "min_rtt": m["min_rtt"], "latest_rtt": ""}
                w.writerow(row)
        print(f"wrote {len(metrics)} rows -> {args.csv}", file=sys.stderr)

    if args.summary:
        summarize(metrics, markers, rebind_events, congestion_events, connstats_lines,
                  label=labels.get("arm", args.log.split("/")[-1]))


if __name__ == "__main__":
    main()
