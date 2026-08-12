#!/usr/bin/env bash
# train_length_sweep.sh -- answers the Phase-0 "short probe train" question:
#
#   the real research sends probe trains of K=5..8 packets, not the 20 the
#   original calibration used. A tbf burst of B bytes lets
#   floor(B/wire_bytes) packets through at line rate before the bucket
#   empties, contaminating that many LEADING inter-arrival gaps with
#   fictitious multi-Gbit/s readings. With K=20 (19 gaps) a couple of
#   contaminated leading gaps are a small fraction and a median absorbs
#   them; with K=5 (4 gaps) the same contamination can be HALF the data,
#   which breaks a median outright. This script measures, empirically,
#   whether --discard-leading (see udp_train.py) recovers an accurate
#   estimate at short train lengths, and if so with which (burst,
#   discard_leading) combination.
#
# Sweeps (all overridable via env vars, defaults match the Phase-0 spec):
#   train length K    in TLS_TRAIN_LENGTHS       (packets per train)
#   burst             in TLS_BURSTS_BYTES         (tbf burst, bytes)
#   rate              in TLS_RATES_MBIT           (tbf configured rate, Mbit/s)
#   discard_leading   in TLS_DISCARD_LEADING      (gaps excluded from stats)
# with >= TLS_REPS repetitions per (K, burst, rate) triple (spec: >=7).
#
# EFFICIENCY / RIGOR NOTE on discard_leading: discard_leading is a pure
# post-hoc statistic over already-captured inter-arrival gaps -- it does
# NOT change what is sent or received on the wire (see udp_train.py's
# compute_stats: the raw gaps_ns/per_packet arrays are identical no matter
# what discard_leading is requested; only which gaps feed the summary
# differs). Re-running the live network experiment once per discard_leading
# value would therefore be 3x redundant AND would inject fresh sampling
# jitter between the three "discard_leading" conditions that has nothing to
# do with discard_leading itself -- a noisier, less rigorous comparison.
# Instead, each (K, burst, rate) rep performs exactly ONE live capture (the
# real `--mode receiver --discard-leading 0` CLI path -- nothing discarded,
# maximal information), and the discard_leading in {0,1,2} variants are
# obtained by calling udp_train.py's OWN `compute_stats()` FUNCTION
# directly (imported, not reimplemented) on that single capture's
# per-packet timestamps. This is the exact code the CLI flag runs -- not an
# approximation -- because compute_stats(packets, sent_count,
# discard_leading) is a pure function of the packet list, and every field
# it needs (seq, timestamp_ns, payload_len) survives in the raw JSON. The
# reconstruction-from-JSON path is round-trip-verified once, automatically,
# as a pre-flight self-test before the sweep proper runs (see below) --
# it recomputes discard_leading=0 from a live JSON's own per_packet data and
# asserts the result matches that JSON's own stored summary EXACTLY.
#
# DIRECTION (Phase-0 audit FINDING 2): this uses DISPERSION methodology
# (short back-to-back trains), which -- like run_calibration.sh -- sends
# from ns_server to ns_client (the receiver needs kernel rx timestamps and
# must sit on the shaped "down" egress' far side).
#
# Expects the topology already up (same convention as run_calibration.sh):
# this script does not call setup_topology.sh/teardown_topology.sh itself.
#
# Outputs:
#   stdout                                                          human-readable table + question (c) answer
#   /home/sivaa/pvseed/results/raw/train_length_sweep_raw.csv        one row per (K,burst,rate,rep,discard_leading)
#   /home/sivaa/pvseed/results/processed/train_length_sweep.csv      one row per (K,burst,rate,discard_leading) cell

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHAPE="$REPO_ROOT/testbed/shaping/apply_shaping.sh"
TRAIN="$REPO_ROOT/testbed/calibration/udp_train.py"
CALIB_DIR="$REPO_ROOT/testbed/calibration"

# --- sweep grid: the Phase-0-required values, overridable ---------------
read -r -a TLS_TRAIN_LENGTHS  <<< "${TLS_TRAIN_LENGTHS:-5 8 12 20}"
read -r -a TLS_BURSTS_BYTES   <<< "${TLS_BURSTS_BYTES:-1600 3200}"
read -r -a TLS_RATES_MBIT     <<< "${TLS_RATES_MBIT:-20 50 100}"
read -r -a TLS_DISCARD_LEADING <<< "${TLS_DISCARD_LEADING:-0 1 2}"

# --- fixed-per-cell parameters (all named, all overridable) -------------
PATH_ID="${TLS_PATH_ID:-a}"
DELAY_MS="${TLS_DELAY_MS:-10}"
LOSS_PCT="${TLS_LOSS_PCT:-0}"
PAYLOAD_BYTES="${TLS_PAYLOAD_BYTES:-1200}"
REPS="${TLS_REPS:-7}"                 # spec requires >=7
LIMIT_PKTS="${TLS_LIMIT_PKTS:-1000}"
PORT="${TLS_PORT:-6100}"
SAFE_THRESHOLD_PCT="${TLS_SAFE_THRESHOLD_PCT:-10}"       # question (c): "within +/-10%"
RECEIVER_STARTUP_S="${TLS_RECEIVER_STARTUP_S:-0.3}"
SHORT_TRAINS_OF_INTEREST="${TLS_SHORT_TRAINS_OF_INTEREST:-5 8}"  # the K values question (c) asks about

log()  { printf '[train_length_sweep] %s\n' "$*" >&2; }
die()  { printf '[train_length_sweep][FATAL] %s\n' "$*" >&2; exit 1; }

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
RAW_CSV="$RESULTS_DIR/raw/train_length_sweep_raw.csv"
PROCESSED_CSV="$RESULTS_DIR/processed/train_length_sweep.csv"
mkdir -p "$(dirname "$RAW_CSV")" "$(dirname "$PROCESSED_CSV")"

WORKDIR="$(mktemp -d /tmp/train_length_sweep.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

# --- PRE-FLIGHT SELF-TEST: prove the JSON-reconstruction path used below to
# get 3 discard_leading variants from 1 live capture is lossless, i.e. that
# recomputing from the reconstructed packets reproduces EXACTLY what the
# live receiver itself stored, before trusting it for the whole sweep. ---
log "pre-flight self-test: verifying JSON-reconstruction is lossless vs. a live capture"
PREFLIGHT_JSON="$WORKDIR/preflight.json"
ip netns exec ns_client python3 "$TRAIN" \
    --mode receiver --bind "$CLIENT_IP" --port "$PORT" --count 20 --discard-leading 0 --out "$PREFLIGHT_JSON" \
    > "$WORKDIR/preflight_recv.log" 2>&1 &
preflight_recv_pid=$!
sleep "$RECEIVER_STARTUP_S"
ip netns exec ns_server python3 "$TRAIN" \
    --mode sender --dst "$CLIENT_IP" --port "$PORT" --count 20 --size "$PAYLOAD_BYTES" \
    > "$WORKDIR/preflight_send.log" 2>&1 \
    || { cat "$WORKDIR/preflight_send.log" >&2; die "pre-flight sender failed"; }
wait "$preflight_recv_pid" || true
[ -s "$PREFLIGHT_JSON" ] || { cat "$WORKDIR/preflight_recv.log" >&2; die "pre-flight capture produced no JSON"; }

python3 - "$PREFLIGHT_JSON" "$CALIB_DIR" <<'PYEOF'
import json, sys
sys.path.insert(0, sys.argv[2])
import udp_train as ut

with open(sys.argv[1]) as f:
    d = json.load(f)

stored_summary = d["summary"]
if stored_summary is None:
    print("PREFLIGHT_FAIL: live capture produced no summary at all (packet loss?)", file=sys.stderr)
    sys.exit(1)

payload_len = stored_summary["payload_len_bytes"]
reconstructed = [
    {"seq": p["seq"], "timestamp_ns": p["timestamp_ns"], "payload_len": payload_len}
    for p in d["per_packet"]
]
recomputed = ut.compute_stats(reconstructed, d["packets_sent"], discard_leading=0)
recomputed_summary = recomputed["summary"]

mismatches = []
for key in stored_summary:
    if stored_summary[key] != recomputed_summary.get(key):
        mismatches.append((key, stored_summary[key], recomputed_summary.get(key)))

if mismatches:
    print(f"PREFLIGHT_FAIL: {len(mismatches)} field(s) differ between live summary and JSON-reconstructed recompute:", file=sys.stderr)
    for k, a, b in mismatches:
        print(f"  {k}: stored={a!r} recomputed={b!r}", file=sys.stderr)
    sys.exit(1)

if recomputed["gap_discarded_leading"] != d["gap_discarded_leading"]:
    print("PREFLIGHT_FAIL: gap_discarded_leading differs after reconstruction", file=sys.stderr)
    sys.exit(1)

print(f"PREFLIGHT_OK: reconstruction is lossless (n_gaps={stored_summary['n_gaps']}, median_rate_bps={stored_summary['median_rate_bps']:.0f})", file=sys.stderr)
PYEOF
PREFLIGHT_RC=$?
if [ "$PREFLIGHT_RC" -ne 0 ]; then
    die "pre-flight self-test FAILED -- refusing to run the sweep on an unverified reconstruction path"
fi
log "pre-flight self-test PASSED -- reconstruction path verified lossless"

echo "k,burst_bytes,rate_mbit,rep,discard_leading,measured_median_rate_bps,iqr_over_median,n_gaps_kept,packets_received,packets_sent" > "$RAW_CSV"
echo "k,burst_bytes,rate_mbit,discard_leading,configured_rate_bps,measured_median_rate_bps,relative_error_pct,iqr_over_median_median,reps,within_${SAFE_THRESHOLD_PCT}pct" > "$PROCESSED_CSV"

log "topology check OK. path=$PATH_ID client_ip=$CLIENT_IP"
log "sweep: K=(${TLS_TRAIN_LENGTHS[*]}) bursts=(${TLS_BURSTS_BYTES[*]}) rates=(${TLS_RATES_MBIT[*]}) discard_leading=(${TLS_DISCARD_LEADING[*]}) reps=$REPS delay_ms=$DELAY_MS payload=$PAYLOAD_BYTES"

printf '\n%-4s %-9s %-9s %-9s %-16s %-18s %-10s %-11s %s\n' \
    "K" "Burst(B)" "Rate(Mb)" "Discard" "Configured(bps)" "Measured(bps)" "RelErr(%)" "IQR/Med" "Safe(<=${SAFE_THRESHOLD_PCT}%)"
printf '%s\n' "-------------------------------------------------------------------------------------------------------------"

for burst in "${TLS_BURSTS_BYTES[@]}"; do
    for rate in "${TLS_RATES_MBIT[@]}"; do
        configured_bps=$(( rate * 1000000 ))

        "$SHAPE" "$PATH_ID" down "$rate" "$DELAY_MS" "$LOSS_PCT" "$burst" "$LIMIT_PKTS" \
            > "$WORKDIR/apply.log" 2>&1 \
            || { cat "$WORKDIR/apply.log" >&2; die "apply_shaping.sh failed for rate=$rate burst=$burst"; }

        for k in "${TLS_TRAIN_LENGTHS[@]}"; do
            # accumulator files: one line per rep per discard_leading value
            for d in "${TLS_DISCARD_LEADING[@]}"; do
                : > "$WORKDIR/acc_${k}_${burst}_${rate}_${d}.txt"
            done

            for rep in $(seq 1 "$REPS"); do
                OUT_JSON="$WORKDIR/cap_${k}_${burst}_${rate}_${rep}.json"
                rm -f "$OUT_JSON"

                ip netns exec ns_client python3 "$TRAIN" \
                    --mode receiver --bind "$CLIENT_IP" --port "$PORT" --count "$k" --discard-leading 0 --out "$OUT_JSON" \
                    > "$WORKDIR/recv.log" 2>&1 &
                recv_pid=$!

                sleep "$RECEIVER_STARTUP_S"

                ip netns exec ns_server python3 "$TRAIN" \
                    --mode sender --dst "$CLIENT_IP" --port "$PORT" --count "$k" --size "$PAYLOAD_BYTES" \
                    > "$WORKDIR/send.log" 2>&1 \
                    || { cat "$WORKDIR/send.log" >&2; die "sender failed for K=$k burst=$burst rate=$rate rep=$rep"; }

                wait "$recv_pid" || true

                if [ ! -s "$OUT_JSON" ]; then
                    cat "$WORKDIR/recv.log" >&2
                    die "no result JSON produced for K=$k burst=$burst rate=$rate rep=$rep"
                fi

                # Recompute all requested discard_leading variants from this
                # ONE live capture via udp_train's own compute_stats() (see
                # header comment -- this is the verified-lossless path).
                python3 - "$OUT_JSON" "$CALIB_DIR" "${TLS_DISCARD_LEADING[@]}" <<'PYEOF' >> "$WORKDIR/discard_results_${k}_${burst}_${rate}_${rep}.txt"
import json, sys
sys.path.insert(0, sys.argv[2])
import udp_train as ut

with open(sys.argv[1]) as f:
    d = json.load(f)

discard_values = [int(x) for x in sys.argv[3:]]
summary0 = d.get("summary")
payload_len = summary0["payload_len_bytes"] if summary0 else None
packets_sent = d["packets_sent"]

for dv in discard_values:
    if summary0 is None:
        print(f"{dv} nan nan 0 {d['packets_received']} {packets_sent}")
        continue
    reconstructed = [
        {"seq": p["seq"], "timestamp_ns": p["timestamp_ns"], "payload_len": payload_len}
        for p in d["per_packet"]
    ]
    r = ut.compute_stats(reconstructed, packets_sent, discard_leading=dv)
    s = r["summary"]
    if s is None or s["median_rate_bps"] is None:
        print(f"{dv} nan nan {s['n_gaps_kept'] if s else 0} {d['packets_received']} {packets_sent}")
    else:
        iqr_med = s["iqr_over_median"] if s["iqr_over_median"] is not None else float("nan")
        print(f"{dv} {s['median_rate_bps']:.6f} {iqr_med:.6f} {s['n_gaps_kept']} {d['packets_received']} {packets_sent}")
PYEOF

                while read -r d_val m_rate m_iqr n_kept n_recv n_sent; do
                    echo "${k},${burst},${rate},${rep},${d_val},${m_rate},${m_iqr},${n_kept},${n_recv},${n_sent}" >> "$RAW_CSV"
                    echo "${m_rate} ${m_iqr}" >> "$WORKDIR/acc_${k}_${burst}_${rate}_${d_val}.txt"
                done < "$WORKDIR/discard_results_${k}_${burst}_${rate}_${rep}.txt"
            done

            # Aggregate across reps, per discard_leading: report MEDIAN (spec).
            for d in "${TLS_DISCARD_LEADING[@]}"; do
                read -r med_rate med_iqr < <(python3 - "$WORKDIR/acc_${k}_${burst}_${rate}_${d}.txt" <<'PYEOF'
import sys, statistics, math
rates, iqrs = [], []
with open(sys.argv[1]) as f:
    for line in f:
        parts = line.split()
        if len(parts) != 2:
            continue
        r, i = parts
        try:
            rv = float(r)
            if not math.isnan(rv):
                rates.append(rv)
        except ValueError:
            pass
        try:
            iv = float(i)
            if not math.isnan(iv):
                iqrs.append(iv)
        except ValueError:
            pass
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

                echo "${k},${burst},${rate},${d},${configured_bps},${med_rate},${rel_err_pct},${med_iqr},${REPS},${within_flag}" >> "$PROCESSED_CSV"

                printf '%-4s %-9s %-9s %-9s %-16s %-18s %-10s %-11s %s\n' \
                    "$k" "$burst" "$rate" "$d" "$configured_bps" "$(printf '%.0f' "$med_rate" 2>/dev/null || echo nan)" \
                    "$rel_err_pct" "$med_iqr" "$within_flag"
            done
        done
    done
done

printf '%s\n' "-------------------------------------------------------------------------------------------------------------"
log "raw per-repetition data:  $RAW_CSV"
log "processed per-cell table: $PROCESSED_CSV"

# --- Question (c): for the SHORT train lengths we actually intend to use,
# which (burst, discard_leading) combination is within threshold ACROSS
# ALL TESTED RATES? ---
echo
log "=== Question (c): recommended (burst, discard_leading) for K in {${SHORT_TRAINS_OF_INTEREST}} ==="
python3 - "$PROCESSED_CSV" "$SAFE_THRESHOLD_PCT" "$SHORT_TRAINS_OF_INTEREST" <<'PYEOF'
import csv, sys
path, threshold, short_ks_raw = sys.argv[1], sys.argv[2], sys.argv[3]
short_ks = {int(x) for x in short_ks_raw.split()}

# rows[k][(burst,discard)][rate] = within_threshold bool
rows = {}
rates = set()
for row in csv.DictReader(open(path)):
    k = int(row["k"])
    if k not in short_ks:
        continue
    burst = int(row["burst_bytes"])
    discard = int(row["discard_leading"])
    rate = int(row["rate_mbit"])
    rates.add(rate)
    rows.setdefault(k, {}).setdefault((burst, discard), {})[rate] = (row[f"within_{threshold}pct"] == "yes")

any_pass = False
for k in sorted(short_ks):
    print(f"\n  K={k}:", file=sys.stderr)
    combos = rows.get(k, {})
    if not combos:
        print(f"    NO DATA for K={k}", file=sys.stderr)
        continue
    for (burst, discard) in sorted(combos):
        per_rate = combos[(burst, discard)]
        all_safe = len(per_rate) > 0 and all(per_rate.get(r, False) for r in rates)
        detail = ", ".join(f"{r}Mbit={'OK' if per_rate.get(r, False) else 'FAIL'}" for r in sorted(rates))
        verdict = "WORKS across all tested rates" if all_safe else "fails for at least one rate"
        marker = " <== CANDIDATE" if all_safe else ""
        if all_safe:
            any_pass = True
        print(f"    burst={burst:>5}B discard_leading={discard}  {verdict:<28} [{detail}]{marker}", file=sys.stderr)

print(file=sys.stderr)
if any_pass:
    print("  OVERALL: at least one (burst, discard_leading) combination keeps short trains within "
          f"+/-{threshold}% across all tested rates -- see CANDIDATE lines above.", file=sys.stderr)
else:
    print("  OVERALL: NO (burst, discard_leading) combination tested keeps short trains within "
          f"+/-{threshold}% across all tested rates. Short trains do not work with the tested grid.", file=sys.stderr)
PYEOF
