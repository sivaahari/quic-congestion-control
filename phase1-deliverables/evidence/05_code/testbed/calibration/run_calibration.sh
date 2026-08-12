#!/usr/bin/env bash
# run_calibration.sh -- the Phase-0 gate.
#
# Sweeps configured rate x tbf burst on path A's downlink (server -> client)
# and measures what packet-dispersion actually recovers, to find the burst
# region where the emulator measures the LINK and not its own token bucket.
#
# For each (rate, burst) cell: apply shaping (delay=10ms, loss=0 by default),
# fire a back-to-back UDP train from ns_server to the path-A client address,
# receive it in ns_client with kernel rx timestamps, and record the measured
# median rate / relative error / IQR-over-median. Each cell is repeated
# multiple times (default 5) and the reported figures are the MEDIAN across
# repetitions, per the Phase-0 spec.
#
# Every tunable below has a name and a default matching the spec's required
# sweep; override any of them via environment variables, e.g.:
#   REPS=10 RATES_MBIT="10 40" ./run_calibration.sh
#
# Outputs:
#   stdout                                    human-readable summary table
#   /home/sivaa/pvseed/results/raw/calibration_raw.csv        every single repetition
#   /home/sivaa/pvseed/results/processed/calibration.csv       per-cell medians (the gate's verdict)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHAPE="$REPO_ROOT/testbed/shaping/apply_shaping.sh"
TRAIN="$REPO_ROOT/testbed/calibration/udp_train.py"

# --- sweep grid: the Phase-0-required values, overridable for follow-on work ---
read -r -a RATES_MBIT   <<< "${RATES_MBIT:-5 20 50 100}"
read -r -a BURSTS_BYTES <<< "${BURSTS_BYTES:-1600 3200 8000 32000 128000}"

# --- fixed-per-cell parameters (all named, all overridable, none buried) ---
PATH_ID="${PATH_ID:-a}"              # which path's bottleneck to shape (a|b)
DELAY_MS="${DELAY_MS:-10}"           # netem delay applied alongside the tbf rate/burst under test
LOSS_PCT="${LOSS_PCT:-0}"            # netem loss -- 0 so any packet loss we see is burst/queue-driven, not injected
PAYLOAD_BYTES="${PAYLOAD_BYTES:-1200}"
COUNT="${COUNT:-20}"                 # packets per train
REPS="${REPS:-5}"                    # repetitions per cell; spec requires >=5
LIMIT_PKTS="${LIMIT_PKTS:-1000}"     # tbf queue limit in packets (generous vs a 20-packet train; matches netem's own default queue depth)
PORT="${PORT:-6000}"
SAFE_THRESHOLD_PCT="${SAFE_THRESHOLD_PCT:-10}"  # "safe burst" = within this many percent of configured rate
RECEIVER_STARTUP_S="${RECEIVER_STARTUP_S:-0.3}" # grace period for the receiver to bind before the sender fires (not part of the timed train itself)

# --- sustained-throughput check parameters (Phase-0 audit FINDING 3: a
# short dispersion train cannot detect a burst that throttles a long-lived
# flow -- that trade-off needs its own, repeated, TCP-based measurement).
# Reuses the SAME rate/burst grid as the dispersion sweep above (RATES_MBIT
# / BURSTS_BYTES) so the two checks can be intersected into one verdict. ---
SUSTAINED_REPS="${SUSTAINED_REPS:-5}"                          # spec requires >=5
SUSTAINED_DURATION_S="${SUSTAINED_DURATION_S:-6}"              # length of each TCP blast, seconds
SUSTAINED_DELAY_MS="${SUSTAINED_DELAY_MS:-0}"                  # 0 isolates the tbf-burst effect from queuing/RTT effects
SUSTAINED_LOSS_PCT="${SUSTAINED_LOSS_PCT:-0}"
SUSTAINED_GOODPUT_RATIO="${SUSTAINED_GOODPUT_RATIO:-0.96}"     # TCP/IP/Ethernet header overhead ceiling vs the raw configured rate
SUSTAINED_SAFE_THRESHOLD_PCT="${SUSTAINED_SAFE_THRESHOLD_PCT:-10}"  # "sustains" = within this many percent of the ceiling above

# This script implements the specific downlink methodology the Phase-0 spec
# asks for: sender in ns_server, receiver in ns_client, shaping applied to
# the client-facing egress of the chosen path's bottleneck ("down"
# direction). Direction is intentionally not a free parameter here -- an
# "up" test would require swapping which namespace sends and which
# receives, which is out of scope for this specific gate script.
DIRECTION="down"

log()  { printf '[run_calibration] %s\n' "$*" >&2; }
die()  { printf '[run_calibration][FATAL] %s\n' "$*" >&2; exit 1; }

case "$PATH_ID" in
    a) CLIENT_IP=10.0.1.1 ;;
    b) CLIENT_IP=10.0.3.1 ;;
    *) die "PATH_ID must be 'a' or 'b', got: $PATH_ID" ;;
esac

for ns in ns_client ns_bottle_a ns_bottle_b ns_server; do
    ip netns list | awk '{print $1}' | grep -qx "$ns" \
        || die "namespace $ns does not exist -- run testbed/topology/setup_topology.sh first"
done

RESULTS_DIR="$REPO_ROOT/results"
RAW_CSV="$RESULTS_DIR/raw/calibration_raw.csv"
PROCESSED_CSV="$RESULTS_DIR/processed/calibration.csv"
mkdir -p "$(dirname "$RAW_CSV")" "$(dirname "$PROCESSED_CSV")"

WORKDIR="$(mktemp -d /tmp/calibration.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "rate_mbit,burst_bytes,rep,measured_median_rate_bps,iqr_over_median,packets_received,packets_sent" > "$RAW_CSV"
echo "rate_mbit,burst_bytes,configured_rate_bps,measured_median_rate_bps,relative_error_pct,iqr_over_median,reps,within_${SAFE_THRESHOLD_PCT}pct" > "$PROCESSED_CSV"

log "topology check OK. path=$PATH_ID direction=$DIRECTION client_ip=$CLIENT_IP"
log "sweep: rates_mbit=(${RATES_MBIT[*]}) bursts_bytes=(${BURSTS_BYTES[*]}) delay_ms=$DELAY_MS loss_pct=$LOSS_PCT payload=$PAYLOAD_BYTES count=$COUNT reps=$REPS limit_pkts=$LIMIT_PKTS"

printf '\n%-9s %-10s %-16s %-18s %-10s %-11s %s\n' "Rate(Mb)" "Burst(B)" "Configured(bps)" "Measured(bps)" "RelErr(%)" "IQR/Med" "Safe(<=${SAFE_THRESHOLD_PCT}%)"
printf '%s\n' "---------------------------------------------------------------------------------------------------"

for rate in "${RATES_MBIT[@]}"; do
    configured_bps=$(( rate * 1000000 ))

    for burst in "${BURSTS_BYTES[@]}"; do
        rate_samples=()
        iqr_samples=()

        for rep in $(seq 1 "$REPS"); do
            "$SHAPE" "$PATH_ID" "$DIRECTION" "$rate" "$DELAY_MS" "$LOSS_PCT" "$burst" "$LIMIT_PKTS" \
                > "$WORKDIR/apply.log" 2>&1 \
                || { cat "$WORKDIR/apply.log" >&2; die "apply_shaping.sh failed for rate=$rate burst=$burst rep=$rep"; }

            OUT_JSON="$WORKDIR/result_${rate}_${burst}_${rep}.json"
            rm -f "$OUT_JSON"

            ip netns exec ns_client python3 "$TRAIN" \
                --mode receiver --bind "$CLIENT_IP" --port "$PORT" --count "$COUNT" --out "$OUT_JSON" \
                > "$WORKDIR/recv.log" 2>&1 &
            recv_pid=$!

            sleep "$RECEIVER_STARTUP_S"

            ip netns exec ns_server python3 "$TRAIN" \
                --mode sender --dst "$CLIENT_IP" --port "$PORT" --count "$COUNT" --size "$PAYLOAD_BYTES" \
                > "$WORKDIR/send.log" 2>&1 \
                || { cat "$WORKDIR/send.log" >&2; die "sender failed for rate=$rate burst=$burst rep=$rep"; }

            wait "$recv_pid" || true

            if [ ! -s "$OUT_JSON" ]; then
                cat "$WORKDIR/recv.log" >&2
                die "no result JSON produced for rate=$rate burst=$burst rep=$rep"
            fi

            read -r m_rate m_iqr n_recv n_sent < <(python3 - "$OUT_JSON" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
s = d.get("summary")
recv = d["packets_received"]
sent = d["packets_sent"]
if s is None or s.get("median_rate_bps") is None:
    print(f"nan nan {recv} {sent}")
else:
    iqr = s.get("iqr_over_median")
    print(f"{s['median_rate_bps']:.6f} {iqr if iqr is not None else 'nan'} {recv} {sent}")
PYEOF
)
            rate_samples+=("$m_rate")
            iqr_samples+=("$m_iqr")

            echo "${rate},${burst},${rep},${m_rate},${m_iqr},${n_recv},${n_sent}" >> "$RAW_CSV"

            if [ "$n_recv" != "$n_sent" ]; then
                log "WARNING rate=$rate burst=$burst rep=$rep: only $n_recv/$n_sent packets received"
            fi
        done

        # Aggregate across repetitions: report the MEDIAN, per spec.
        read -r med_rate med_iqr < <(python3 - "${rate_samples[@]}" -- "${iqr_samples[@]}" <<'PYEOF'
import sys, statistics, math

def parse(lst):
    out = []
    for x in lst:
        try:
            v = float(x)
        except ValueError:
            continue
        if not math.isnan(v):
            out.append(v)
    return out

args = sys.argv[1:]
sep = args.index("--")
rates = parse(args[:sep])
iqrs = parse(args[sep + 1:])
med_rate = statistics.median(rates) if rates else float("nan")
med_iqr = statistics.median(iqrs) if iqrs else float("nan")
print(f"{med_rate:.6f} {med_iqr:.6f}")
PYEOF
)

        read -r rel_err_pct within_flag < <(python3 -c "
import math
m = float('$med_rate')
c = float($configured_bps)
if math.isnan(m):
    print('nan no')
else:
    err = ((m - c) / c) * 100.0
    flag = 'yes' if abs(err) <= ${SAFE_THRESHOLD_PCT}.0 else 'no'
    print(f'{err:.3f} {flag}')
")

        echo "${rate},${burst},${configured_bps},${med_rate},${rel_err_pct},${med_iqr},${REPS},${within_flag}" >> "$PROCESSED_CSV"

        printf '%-9s %-10s %-16s %-18s %-10s %-11s %s\n' \
            "$rate" "$burst" "$configured_bps" "$(printf '%.0f' "$med_rate")" "$rel_err_pct" "$med_iqr" "$within_flag"
    done
done

printf '%s\n' "---------------------------------------------------------------------------------------------------"
log "raw per-repetition data:  $RAW_CSV"
log "processed per-cell table: $PROCESSED_CSV"

# --- Safe-burst-region determination: bursts that stay within threshold across EVERY tested rate ---
echo
log "safe burst region (burst values within +/-${SAFE_THRESHOLD_PCT}% of configured rate, ACROSS ALL TESTED RATES):"
python3 - "$PROCESSED_CSV" "$SAFE_THRESHOLD_PCT" <<'PYEOF'
import csv, sys
path, threshold = sys.argv[1], sys.argv[2]
by_burst = {}
rates = set()
with open(path) as f:
    for row in csv.DictReader(f):
        burst = int(row["burst_bytes"])
        rate = int(row["rate_mbit"])
        rates.add(rate)
        by_burst.setdefault(burst, {})[rate] = row[f"within_{threshold}pct"] == "yes"

for burst in sorted(by_burst):
    per_rate = by_burst[burst]
    all_safe = all(per_rate.get(r, False) for r in rates)
    detail = ", ".join(f"{r}Mbit={'OK' if per_rate.get(r, False) else 'TRAP'}" for r in sorted(rates))
    verdict = "SAFE across all tested rates" if all_safe else "unsafe for at least one rate"
    print(f"  burst={burst:>7}B  {verdict:<32} [{detail}]", file=sys.stderr)
PYEOF

# ---------------------------------------------------------------------------
# Phase 2 (Phase-0 audit FINDING 3 / task d): the dispersion sweep above
# uses a short back-to-back train and CANNOT detect a burst that throttles
# a long-lived flow -- that is a separate failure mode requiring a real,
# repeated, sustained TCP transfer. Reuses this script's own RATES_MBIT /
# BURSTS_BYTES grid so the two checks share a burst axis and can be
# intersected below into one combined verdict.
# ---------------------------------------------------------------------------
echo
log "=== Phase 2: sustained-throughput check (same rate/burst grid, ${SUSTAINED_REPS} reps x ${SUSTAINED_DURATION_S}s each) ==="
SUSTAINED_PROCESSED_CSV="$RESULTS_DIR/processed/sustained.csv"
SUS_RATES_MBIT="${RATES_MBIT[*]}" \
SUS_BURSTS_BYTES="${BURSTS_BYTES[*]}" \
SUS_REPS="$SUSTAINED_REPS" \
SUS_DURATION_S="$SUSTAINED_DURATION_S" \
SUS_DELAY_MS="$SUSTAINED_DELAY_MS" \
SUS_LOSS_PCT="$SUSTAINED_LOSS_PCT" \
SUS_EXPECTED_GOODPUT_RATIO="$SUSTAINED_GOODPUT_RATIO" \
SUS_SAFE_THRESHOLD_PCT="$SUSTAINED_SAFE_THRESHOLD_PCT" \
PATH_ID="$PATH_ID" \
    bash "$REPO_ROOT/testbed/calibration/sustained_throughput.sh" \
    || die "sustained_throughput.sh failed"

# ---------------------------------------------------------------------------
# FINAL VERDICT: a burst value only qualifies as the Phase-0 recommendation
# if it is safe on BOTH axes -- dispersion accuracy (this script's own
# sweep, table above) AND sustained throughput (Phase 2, just above).
# Prints a clear PASS/FAIL banner and, on PASS, the smallest qualifying
# burst (smaller bursts contaminate fewer leading packets of a probe train,
# so "smallest safe burst" is the right tie-break).
# ---------------------------------------------------------------------------
echo
log "=== FINAL PHASE-0 GATE VERDICT: dispersion accuracy AND sustained throughput ==="
# NOTE: under `set -e`, a bare failing command aborts the script immediately
# -- which would skip GATE_RC=$? and the log lines below on the FAIL path.
# Wrapping in `if` is the standard set-e-safe way to run a command whose
# non-zero exit we want to inspect ourselves rather than have `-e` act on.
if python3 - "$PROCESSED_CSV" "$SUSTAINED_PROCESSED_CSV" "$SAFE_THRESHOLD_PCT" "$SUSTAINED_SAFE_THRESHOLD_PCT" <<'PYEOF'
import csv, sys

disp_path, sus_path, disp_thresh, sus_thresh = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def per_burst_safety(path, within_col):
    by_burst = {}
    rates = set()
    with open(path) as f:
        for row in csv.DictReader(f):
            burst = int(row["burst_bytes"])
            rate = int(float(row["rate_mbit"]))
            rates.add(rate)
            by_burst.setdefault(burst, {})[rate] = (row[within_col] == "yes")
    return {b: (len(v) > 0 and all(v.get(r, False) for r in rates)) for b, v in by_burst.items()}, rates

disp_safe, disp_rates = per_burst_safety(disp_path, f"within_{disp_thresh}pct")
sus_safe, sus_rates = per_burst_safety(sus_path, f"within_{sus_thresh}pct_of_ceiling")

all_bursts = sorted(set(disp_safe) | set(sus_safe))
print(f"  {'burst(B)':>10}  {'dispersion':>12}  {'sustained':>12}  {'overall':>10}", file=sys.stderr)
qualifying = []
for b in all_bursts:
    d_ok = disp_safe.get(b, False)
    s_ok = sus_safe.get(b, False)
    ok = d_ok and s_ok
    if ok:
        qualifying.append(b)
    print(f"  {b:>10}  {('SAFE' if d_ok else 'unsafe'):>12}  {('SAFE' if s_ok else 'unsafe'):>12}  {('PASS' if ok else 'FAIL'):>10}", file=sys.stderr)

print(file=sys.stderr)
print("=" * 72, file=sys.stderr)
if qualifying:
    recommended = min(qualifying)
    print(f"PHASE-0 GATE VERDICT: PASS", file=sys.stderr)
    print(f"RECOMMENDED BURST: {recommended} bytes", file=sys.stderr)
    print(f"  (safe for dispersion accuracy within +/-{disp_thresh}% AND sustained throughput", file=sys.stderr)
    print(f"   within +/-{sus_thresh}% of the goodput ceiling, across every rate tested)", file=sys.stderr)
else:
    print(f"PHASE-0 GATE VERDICT: FAIL", file=sys.stderr)
    print(f"  no tested burst value is safe on BOTH axes -- see the per-burst table above", file=sys.stderr)
    print(f"  for which axis (dispersion and/or sustained) failed at each burst.", file=sys.stderr)
print("=" * 72, file=sys.stderr)
sys.exit(0 if qualifying else 1)
PYEOF
then
    GATE_RC=0
else
    GATE_RC=$?
fi

log "dispersion table:  $PROCESSED_CSV"
log "sustained table:   $SUSTAINED_PROCESSED_CSV"

exit "$GATE_RC"
