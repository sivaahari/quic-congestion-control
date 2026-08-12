#!/usr/bin/env bash
# sustained_throughput.sh -- CHECK 2 from the Phase-0 audit, made permanent
# and repeated.
#
# The dispersion sweep (run_calibration.sh) only ever fires a short
# back-to-back UDP train, which by construction cannot detect a tbf burst
# setting that THROTTLES a long-lived flow -- that is the other half of the
# burst trade-off (a burst big enough to pass a whole probe train at line
# rate is bad for dispersion accuracy; a burst too small to refill fast
# enough starves a sustained flow of its configured rate). This script
# measures that second failure mode directly, with real repetitions.
#
# DIRECTION MATTERS (Phase-0 audit FINDING 2): `apply_shaping.sh <path>
# down` shapes the SERVER->CLIENT egress inside the bottleneck namespace.
# The traffic generator MUST therefore run the sender in ns_server and the
# sink in ns_client -- running it the other way traverses the unshaped
# uplink and "measures" raw veth speed (tens of Gbit/s), which is a test
# bug, not a shaping result. This mirrors testbed/calibration/audit_sustained.sh.
#
# Judging against the right ceiling: TCP/IP/Ethernet header overhead means
# even a perfect, unthrottled tbf cannot deliver 100% of the configured
# rate as TCP goodput -- the audit measured ~95-96% at the rates tested.
# Achieved throughput is therefore judged against
# `configured_rate * EXPECTED_GOODPUT_RATIO`, not against the raw
# configured rate.
#
# Usage (expects the topology already up -- this script does not call
# setup_topology.sh/teardown_topology.sh itself, matching run_calibration.sh's
# convention, so multiple calibration scripts can share one topology
# instance in a single WSL invocation):
#   sustained_throughput.sh
#
# All tunables are environment-variable overridable, e.g.:
#   SUS_RATES_MBIT="5 50 100" SUS_BURSTS_BYTES="1600 3200 8000 32000" SUS_REPS=5 \
#       ./sustained_throughput.sh
#
# Outputs:
#   stdout                                                human-readable summary table
#   /home/sivaa/pvseed/results/raw/sustained_raw.csv       every single repetition
#   /home/sivaa/pvseed/results/processed/sustained.csv     per-cell median/min/max + verdict

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHAPE="$REPO_ROOT/testbed/shaping/apply_shaping.sh"

# --- sweep grid (overridable) --------------------------------------------
read -r -a SUS_RATES_MBIT   <<< "${SUS_RATES_MBIT:-5 50 100}"
read -r -a SUS_BURSTS_BYTES <<< "${SUS_BURSTS_BYTES:-1600 3200 8000 32000}"

# --- fixed-per-cell parameters (named, overridable, nothing buried) ------
PATH_ID="${PATH_ID:-a}"
DELAY_MS="${SUS_DELAY_MS:-0}"                 # netem delay; 0 isolates the tbf-burst effect from queuing/RTT effects
LOSS_PCT="${SUS_LOSS_PCT:-0}"                  # netem loss; 0 so any shortfall is burst-driven, not injected
LIMIT_PKTS="${SUS_LIMIT_PKTS:-1000}"
SUS_REPS="${SUS_REPS:-5}"                     # spec requires >=5 repetitions per cell
DURATION_S="${SUS_DURATION_S:-6}"             # length of each TCP blast, seconds
PORT="${SUS_PORT:-5555}"
SINK_STARTUP_S="${SUS_SINK_STARTUP_S:-0.7}"   # grace period for the sink to bind+listen before the blaster connects
SINK_TIMEOUT_MARGIN_S="${SUS_SINK_TIMEOUT_MARGIN_S:-25}"   # sink's `timeout` budget = DURATION_S + this margin
BLAST_TIMEOUT_MARGIN_S="${SUS_BLAST_TIMEOUT_MARGIN_S:-19}" # blaster's `timeout` budget = DURATION_S + this margin
EXPECTED_GOODPUT_RATIO="${SUS_EXPECTED_GOODPUT_RATIO:-0.96}"  # TCP/IP/Ethernet overhead ceiling vs the raw configured rate
SAFE_THRESHOLD_PCT="${SUS_SAFE_THRESHOLD_PCT:-10}"            # "sustains" = within this many percent of the ceiling above

log()  { printf '[sustained] %s\n' "$*" >&2; }
die()  { printf '[sustained][FATAL] %s\n' "$*" >&2; exit 1; }

case "$PATH_ID" in
    a) CLIENT_IP=10.0.1.1 ;;
    b) CLIENT_IP=10.0.3.1 ;;
    *) die "PATH_ID must be 'a' or 'b', got: $PATH_ID" ;;
esac
SERVICE_IP=10.0.9.1   # server's stable address; the blaster binds this as its source (models QUIC's fixed server identity)

for ns in ns_client ns_bottle_a ns_bottle_b ns_server; do
    ip netns list | awk '{print $1}' | grep -qx "$ns" \
        || die "namespace $ns does not exist -- run testbed/topology/setup_topology.sh first"
done

RESULTS_DIR="$REPO_ROOT/results"
RAW_CSV="$RESULTS_DIR/raw/sustained_raw.csv"
PROCESSED_CSV="$RESULTS_DIR/processed/sustained.csv"
mkdir -p "$(dirname "$RAW_CSV")" "$(dirname "$PROCESSED_CSV")"

WORKDIR="$(mktemp -d /tmp/sustained.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

cat > "$WORKDIR/sink.py" <<'PYEOF'
import socket, sys, time
# argv: bind_ip port
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((sys.argv[1], int(sys.argv[2]))); s.listen(1); s.settimeout(25)
try:
    c, _ = s.accept()
except Exception:
    print("ACCEPT_TIMEOUT"); sys.exit(1)
c.settimeout(25)
n = 0; t0 = None
try:
    while True:
        b = c.recv(262144)
        if not b: break
        if t0 is None: t0 = time.perf_counter()
        n += len(b)
except Exception:
    pass
dur = (time.perf_counter() - t0) if t0 else 0
print("%.6f" % ((n*8/dur)/1e6 if dur > 0 else 0))
PYEOF

cat > "$WORKDIR/blast.py" <<'PYEOF'
import socket, sys, time
# argv: dst port duration src
s = socket.socket()
s.bind((sys.argv[4], 0))   # source = server's stable service address (models fixed server identity)
s.settimeout(15)
s.connect((sys.argv[1], int(sys.argv[2])))
buf = b'x' * 65536
end = time.perf_counter() + float(sys.argv[3])
try:
    while time.perf_counter() < end:
        s.sendall(buf)
except Exception as e:
    print("BLAST_ERR", e, file=sys.stderr)
s.close()
PYEOF

echo "rate_mbit,burst_bytes,rep,achieved_mbps" > "$RAW_CSV"
echo "rate_mbit,burst_bytes,configured_mbit,ceiling_mbit,reps,median_mbps,min_mbps,max_mbps,relative_error_vs_ceiling_pct,within_${SAFE_THRESHOLD_PCT}pct_of_ceiling" > "$PROCESSED_CSV"

log "topology check OK. path=$PATH_ID direction=down(server->client) client_ip=$CLIENT_IP"
log "sweep: rates_mbit=(${SUS_RATES_MBIT[*]}) bursts_bytes=(${SUS_BURSTS_BYTES[*]}) delay_ms=$DELAY_MS loss_pct=$LOSS_PCT duration_s=$DURATION_S reps=$SUS_REPS goodput_ratio=$EXPECTED_GOODPUT_RATIO"

printf '\n%-9s %-10s %-9s %-10s %-10s %-10s %-10s %-10s %s\n' \
    "Rate(Mb)" "Burst(B)" "Reps" "Med(Mb)" "Min(Mb)" "Max(Mb)" "Ceil(Mb)" "RelErr%" "Sustains(<=${SAFE_THRESHOLD_PCT}%)"
printf '%s\n' "----------------------------------------------------------------------------------------------"

for rate in "${SUS_RATES_MBIT[@]}"; do
    for burst in "${SUS_BURSTS_BYTES[@]}"; do
        "$SHAPE" "$PATH_ID" down "$rate" "$DELAY_MS" "$LOSS_PCT" "$burst" "$LIMIT_PKTS" \
            > "$WORKDIR/apply.log" 2>&1 \
            || { cat "$WORKDIR/apply.log" >&2; die "apply_shaping.sh failed for rate=$rate burst=$burst"; }

        samples=()
        sink_timeout=$(( DURATION_S + SINK_TIMEOUT_MARGIN_S ))
        blast_timeout=$(( DURATION_S + BLAST_TIMEOUT_MARGIN_S ))

        for rep in $(seq 1 "$SUS_REPS"); do
            : > "$WORKDIR/sink_out.txt"
            ip netns exec ns_client timeout "$sink_timeout" python3 "$WORKDIR/sink.py" "$CLIENT_IP" "$PORT" \
                > "$WORKDIR/sink_out.txt" 2>/dev/null &
            sink_pid=$!
            sleep "$SINK_STARTUP_S"

            ip netns exec ns_server timeout "$blast_timeout" python3 "$WORKDIR/blast.py" \
                "$CLIENT_IP" "$PORT" "$DURATION_S" "$SERVICE_IP" >/dev/null 2>&1

            wait "$sink_pid" 2>/dev/null
            achieved=$(cat "$WORKDIR/sink_out.txt" 2>/dev/null)
            [ -z "$achieved" ] && achieved="nan"
            samples+=("$achieved")
            echo "${rate},${burst},${rep},${achieved}" >> "$RAW_CSV"
        done

        read -r med_mbps min_mbps max_mbps < <(python3 - "${samples[@]}" <<'PYEOF'
import sys, statistics, math
vals = []
for x in sys.argv[1:]:
    try:
        v = float(x)
        if not math.isnan(v):
            vals.append(v)
    except ValueError:
        pass
if vals:
    print(f"{statistics.median(vals):.6f} {min(vals):.6f} {max(vals):.6f}")
else:
    print("nan nan nan")
PYEOF
)

        read -r ceiling_mbit rel_err_pct within_flag < <(python3 -c "
import math
rate = float($rate)
med = float('$med_mbps')
ratio = float($EXPECTED_GOODPUT_RATIO)
ceiling = rate * ratio
if math.isnan(med):
    print(f'{ceiling:.6f} nan no')
else:
    err = ((med - ceiling) / ceiling) * 100.0
    flag = 'yes' if abs(err) <= ${SAFE_THRESHOLD_PCT}.0 else 'no'
    print(f'{ceiling:.6f} {err:.3f} {flag}')
")

        echo "${rate},${burst},${rate},${ceiling_mbit},${SUS_REPS},${med_mbps},${min_mbps},${max_mbps},${rel_err_pct},${within_flag}" >> "$PROCESSED_CSV"

        printf '%-9s %-10s %-9s %-10s %-10s %-10s %-10s %-10s %s\n' \
            "$rate" "$burst" "$SUS_REPS" \
            "$(printf '%.3f' "$med_mbps")" "$(printf '%.3f' "$min_mbps")" "$(printf '%.3f' "$max_mbps")" \
            "$(printf '%.3f' "$ceiling_mbit")" "$rel_err_pct" "$within_flag"
    done
done

printf '%s\n' "----------------------------------------------------------------------------------------------"
log "raw per-repetition data:  $RAW_CSV"
log "processed per-cell table: $PROCESSED_CSV"

echo
log "burst values that SUSTAIN the ceiling across ALL tested rates:"
python3 - "$PROCESSED_CSV" "$SAFE_THRESHOLD_PCT" <<'PYEOF'
import csv, sys
path, threshold = sys.argv[1], sys.argv[2]
by_burst = {}
rates = set()
with open(path) as f:
    for row in csv.DictReader(f):
        burst = int(row["burst_bytes"])
        rate = int(float(row["rate_mbit"]))
        rates.add(rate)
        by_burst.setdefault(burst, {})[rate] = row[f"within_{threshold}pct_of_ceiling"] == "yes"

for burst in sorted(by_burst):
    per_rate = by_burst[burst]
    all_safe = all(per_rate.get(r, False) for r in rates)
    detail = ", ".join(f"{r}Mbit={'OK' if per_rate.get(r, False) else 'THROTTLES'}" for r in sorted(rates))
    verdict = "SUSTAINS across all tested rates" if all_safe else "throttles at least one rate"
    print(f"  burst={burst:>7}B  {verdict:<30} [{detail}]", file=sys.stderr)
PYEOF
