#!/usr/bin/env python3
"""build_baseline_dataset.py -- TASK C: builds the tidy per-sample CSV and
the derived per-trial summary CSV for the Phase 1 baseline migration
comparison (STEP-UP / STEP-DOWN x NAIVE / SPEC_RESET).

Reads every trial's SERVER qlog under
  results/raw/baseline/<scenario>/<arm>/rep<N>/final/qlog_server/*.server.qlog
("final" is a symlink written by testbed/scenarios/run_baseline_suite.sh
pointing at the last -- hopefully successful -- attempt for that cell; a
trial is retried up to 3x if the download didn't complete).

Only the SERVER qlog is used anywhere in this script: the server is the
data sender for a download, so its congestion controller is what governs
throughput (matches parse_qlog.py's existing convention).

Writes:
  results/processed/baseline_migration.csv
      Tidy time series, one row per metrics_updated sample:
      scenario, arm, rep, time_us, cwnd, bytes_in_flight, smoothed_rtt,
      min_rtt, latest_rtt

  results/processed/baseline_summary.csv
      One row per trial with the derived metrics defined below.

================================================================================
DEFINITIONS (stated explicitly, as required by the task)
================================================================================
migration window [t0, t1]
    t0 = min, t1 = max relative_time (us) of any path_challenge/
    path_response frame seen in the SERVER qlog. t1 ("migration
    completion": the last path-validation frame exchanged) is the
    reference point for every "after migration" window below.

achievable rate
    The new path's (path B) shaped tbf rate in bit/s, read directly out of
    the trial's own shaping_b.log ("applied: rate=<N>mbit", written by
    apply_shaping.sh) -- NOT re-derived from traffic and NOT hardcoded
    here, so it can never silently drift out of sync with what a trial
    actually ran under.

throughput
    Sender-side (server) datagram bytes actually put on the wire
    (qlog "datagram_sent" byte_length), bucketed into fixed
    WINDOW_US-wide (200 ms) windows and converted to bit/s. This is a SEND
    rate, not an ack-confirmed goodput rate -- consistent with "the
    server's congestion controller governs throughput". Only FULL windows
    are counted; a trailing partial window (less than WINDOW_US of data
    available) is dropped rather than reported as a misleadingly low
    bucket.

"sustained >=90%" / recovery time
    recovery time = (first window start time t_r, at or after t1, such
    that EVERY window from t_r through t_r + SUSTAIN_US (1 second),
    inclusive, has throughput >= 0.9 * achievable_rate) MINUS t1.
    In words: the send rate must stay at or above 90% of the new path's
    shaped rate for a full continuous 1-second stretch before we call it
    "recovered" -- a single fast 200ms window right after migration does
    not count, so a lucky burst can't be mistaken for sustained recovery.
    If no such window exists before the trial's data runs out, recovery is
    reported as NOT reached (recovered=0, recovery_time_us empty) rather
    than guessed or extrapolated.

byte deficit
    Sum, over windows from t1 to the recovery point (or to the end of the
    trace if recovery was never reached), of
        max(0, achievable_bytes_in_window - actual_bytes_in_window)
    i.e. the total bytes NOT sent that could have been, had the sender
    already been running at the new path's full rate from the instant
    migration completed. This is the throughput-side cost of a slow (or
    fast) climb back to line rate. Per-window deficits are clamped at 0 so
    a window that overshoots the achievable rate cannot cancel out a
    slow window elsewhere in the sum.

2s post-migration window
    The fixed window [t1, t1 + 2,000,000) us. Used for the
    packets-lost-or-retransmitted count and the max-bytes_in_flight
    overshoot proxy. "Packets lost/retransmitted" is operationalized as
    qlog "packet_lost" event count (these are picoquic's own
    loss-detection events, which are what trigger retransmission; qlog
    does not separately tag "this packet is a retransmission").

cwnd before
    cwnd of the last metrics_updated sample with time_us < t0 (i.e.
    immediately before the migration window opens).

cwnd min after
    Minimum cwnd over metrics_updated samples with time_us in
    [t0, t1 + 2,000,000) -- deliberately starting at t0, not t1, so a
    reset that happens WHILE migration/path-validation is still in flight
    is still captured.
================================================================================

Usage:
    build_baseline_dataset.py [--raw-root DIR] [--out-migration-csv FILE]
                               [--out-summary-csv FILE]
"""
import argparse
import csv
import glob
import os
import re
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import parse_qlog  # noqa: E402  (local module; sys.path tweak above)

WINDOW_US = 200_000        # throughput bucket width
SUSTAIN_US = 1_000_000     # must stay >=90% for this long, continuously
POST_MIGRATION_US = 2_000_000
RECOVERY_FRACTION = 0.9

HERE = os.path.dirname(os.path.abspath(__file__))
RAW_ROOT_DEFAULT = os.path.join(HERE, "..", "results", "raw", "baseline")
PROCESSED_DIR_DEFAULT = os.path.join(HERE, "..", "results", "processed")

SCENARIOS = ["step_up", "step_down"]
ARMS = ["naive", "specreset"]


def find_reps(raw_root, scenario, arm):
    pattern = os.path.join(raw_root, scenario, arm, "rep*")
    out = []
    for d in glob.glob(pattern):
        m = re.search(r"rep(\d+)$", d)
        if not m:
            continue
        out.append((int(m.group(1)), os.path.join(d, "final")))
    out.sort(key=lambda x: x[0])
    return out


def read_rate_b_mbit(trial_dir):
    path = os.path.join(trial_dir, "shaping_b.log")
    with open(path) as f:
        text = f.read()
    m = re.search(r"applied:\s*rate=([\d.]+)mbit", text)
    if not m:
        raise RuntimeError(f"could not find applied rate in {path}")
    return float(m.group(1))


def find_server_qlog(trial_dir):
    matches = glob.glob(os.path.join(trial_dir, "qlog_server", "*.server.qlog"))
    if not matches:
        raise RuntimeError(f"no server qlog found under {trial_dir}/qlog_server")
    matches.sort(key=os.path.getmtime)
    return matches[-1]


def bucket_bytes(sent_bytes, start_us, end_us, window_us):
    """Sum byte_length into fixed-width [start_us + k*window_us, +window_us)
    buckets. Only FULL windows are included -- a tail shorter than
    window_us is dropped rather than reported as a partial (and therefore
    misleadingly low) throughput bucket."""
    if end_us <= start_us:
        return []
    n_buckets = int((end_us - start_us) // window_us)
    if n_buckets <= 0:
        return []
    buckets = [0] * n_buckets
    for s in sent_bytes:
        t = s["time_us"]
        if t < start_us:
            continue
        k = int((t - start_us) // window_us)
        if 0 <= k < n_buckets:
            buckets[k] += s["byte_length"]
    return buckets


def find_recovery(buckets, window_us, achievable_bps, sustain_us, fraction):
    """Return (recovery_bucket_index_or_None, recovered_bool)."""
    threshold_bytes = fraction * achievable_bps / 8.0 * (window_us / 1_000_000.0)
    need = max(1, round(sustain_us / window_us))
    qualifies = [b >= threshold_bytes for b in buckets]
    n = len(qualifies)
    for i in range(n):
        if i + need > n:
            break
        if all(qualifies[i:i + need]):
            return i, True
    return None, False


def compute_trial(scenario, arm, rep, trial_dir, processed_dir):
    qlog_path = find_server_qlog(trial_dir)
    trace, idx = parse_qlog.load_trace(qlog_path)
    metrics, path_events, losses, sent_bytes = parse_qlog.extract(trace, idx)
    rate_b_mbit = read_rate_b_mbit(trial_dir)
    achievable_bps = rate_b_mbit * 1_000_000.0

    row = {
        "scenario": scenario, "arm": arm, "rep": rep,
        "rate_b_mbit": rate_b_mbit,
        "qlog": os.path.relpath(qlog_path, processed_dir),
    }

    if not path_events:
        row["migration_detected"] = 0
        return row, metrics

    t0 = min(p["time_us"] for p in path_events)
    t1 = max(p["time_us"] for p in path_events)
    row["migration_detected"] = 1
    row["t0_us"] = t0
    row["t1_us"] = t1

    before = [m for m in metrics if m["time_us"] < t0]
    row["cwnd_before"] = before[-1]["cwnd"] if before else None

    # NOTE: not every metrics_updated sample reports every field (e.g. some
    # report only cwnd, without bytes_in_flight) -- parse_qlog.extract()
    # uses .get() so a missing field comes through as None. Filter those
    # out before min()/max(), which otherwise raise TypeError comparing
    # None against int.
    cwnd_pool = [m for m in metrics if t0 <= m["time_us"] < t1 + POST_MIGRATION_US]
    cwnd_vals = [m["cwnd"] for m in cwnd_pool if m["cwnd"] is not None]
    row["cwnd_min_after"] = min(cwnd_vals, default=None)

    bif_pool = [m for m in metrics if t1 <= m["time_us"] < t1 + POST_MIGRATION_US]
    bif_vals = [m["bytes_in_flight"] for m in bif_pool if m["bytes_in_flight"] is not None]
    row["max_bytes_in_flight_2s"] = max(bif_vals, default=None)

    row["packets_lost_2s"] = sum(1 for l in losses if t1 <= l["time_us"] < t1 + POST_MIGRATION_US)
    row["packets_lost_total"] = len(losses)

    end_us = max([m["time_us"] for m in metrics] + [s["time_us"] for s in sent_bytes] + [t1])
    row["trace_end_us"] = end_us

    buckets = bucket_bytes(sent_bytes, t1, end_us, WINDOW_US)
    rec_idx, recovered = find_recovery(buckets, WINDOW_US, achievable_bps, SUSTAIN_US, RECOVERY_FRACTION)
    row["recovered"] = 1 if recovered else 0
    if recovered:
        row["recovery_time_us"] = rec_idx * WINDOW_US
        deficit_buckets = buckets[:rec_idx]
    else:
        row["recovery_time_us"] = None
        deficit_buckets = buckets

    achievable_bytes_per_window = achievable_bps / 8.0 * (WINDOW_US / 1_000_000.0)
    row["byte_deficit"] = sum(max(0.0, achievable_bytes_per_window - b) for b in deficit_buckets)

    return row, metrics


def fmt(v):
    if v is None:
        return ""
    return v


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw-root", default=RAW_ROOT_DEFAULT)
    ap.add_argument("--out-migration-csv", default=os.path.join(PROCESSED_DIR_DEFAULT, "baseline_migration.csv"))
    ap.add_argument("--out-summary-csv", default=os.path.join(PROCESSED_DIR_DEFAULT, "baseline_summary.csv"))
    args = ap.parse_args()

    processed_dir = os.path.dirname(os.path.abspath(args.out_migration_csv))
    os.makedirs(processed_dir, exist_ok=True)

    migration_rows = []
    summary_rows = []

    for scenario in SCENARIOS:
        for arm in ARMS:
            reps = find_reps(args.raw_root, scenario, arm)
            if not reps:
                print(f"WARNING: no reps found for {scenario}/{arm} under {args.raw_root}", file=sys.stderr)
            for rep, trial_dir in reps:
                if not os.path.isdir(trial_dir):
                    print(f"WARNING: {trial_dir} missing (broken 'final' symlink?), skipping", file=sys.stderr)
                    continue
                try:
                    row, metrics = compute_trial(scenario, arm, rep, trial_dir, processed_dir)
                except Exception as e:
                    print(f"ERROR processing {scenario}/{arm}/rep{rep} ({trial_dir}): {e}", file=sys.stderr)
                    continue
                summary_rows.append(row)
                for m in metrics:
                    migration_rows.append({"scenario": scenario, "arm": arm, "rep": rep, **m})

    mig_cols = ["scenario", "arm", "rep", "time_us", "cwnd", "bytes_in_flight",
                "smoothed_rtt", "min_rtt", "latest_rtt"]
    with open(args.out_migration_csv, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=mig_cols)
        w.writeheader()
        for r in migration_rows:
            w.writerow({k: fmt(r.get(k)) for k in mig_cols})
    print(f"wrote {len(migration_rows)} rows -> {args.out_migration_csv}", file=sys.stderr)

    sum_cols = ["scenario", "arm", "rep", "rate_b_mbit", "migration_detected",
                "t0_us", "t1_us", "cwnd_before", "cwnd_min_after",
                "max_bytes_in_flight_2s", "packets_lost_2s", "packets_lost_total",
                "recovered", "recovery_time_us", "byte_deficit", "trace_end_us", "qlog"]
    with open(args.out_summary_csv, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=sum_cols)
        w.writeheader()
        for r in summary_rows:
            w.writerow({k: fmt(r.get(k)) for k in sum_cols})
    print(f"wrote {len(summary_rows)} rows -> {args.out_summary_csv}", file=sys.stderr)

    print("\n===== per-cell medians (min .. max) =====")
    metric_keys = ["cwnd_before", "cwnd_min_after", "max_bytes_in_flight_2s",
                   "packets_lost_2s", "recovery_time_us", "byte_deficit"]
    for scenario in SCENARIOS:
        for arm in ARMS:
            cell = [r for r in summary_rows if r["scenario"] == scenario and r["arm"] == arm]
            n_detected = sum(1 for r in cell if r.get("migration_detected"))
            n_recovered = sum(1 for r in cell if r.get("recovered"))
            print(f"\n-- {scenario} / {arm} (n={len(cell)}, migration_detected={n_detected}, recovered={n_recovered}) --")
            for key in metric_keys:
                vals = [r[key] for r in cell if r.get(key) is not None]
                n_missing = len(cell) - len(vals)
                if not vals:
                    print(f"  {key:28s}: no data")
                    continue
                med = statistics.median(vals)
                print(f"  {key:28s}: median={med:,.1f}  min={min(vals):,.1f}  max={max(vals):,.1f}"
                      f"{f'  ({n_missing} missing/not-recovered)' if n_missing else ''}")


if __name__ == "__main__":
    main()
