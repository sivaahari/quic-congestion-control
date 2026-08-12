#!/usr/bin/env bash
# The parser's one-line verdict is not evidence. Apply the discriminator
# properly: get picoquic's OWN constants from source, then look at what the
# window actually did at the migration instant in each of the five repetitions.
P=/home/sivaa/pvseed
R=$P/results/raw/picoquic/reps

echo "=== 1. Was the migration a genuine ADDRESS change in each rep? ==="
for i in 1 2 3 4 5; do
    printf '  rep %d: ' "$i"
    grep -aoiE "Simulating migration[^\\n]*" "$R/rep_$i/client_stdout.log" 2>/dev/null | head -1 \
        || echo "(no 'Simulating migration' line)"
done
echo
echo "  any line mentioning a new address / port:"
grep -aoiE "(NEW ADDRESS|new port|migration to)[^\"]{0,60}" "$R/rep_1/client_stdout.log" 2>/dev/null | head -5

echo
echo "=== 2. picoquic's own constants, from ITS source ==="
grep -rnE "define +PICOQUIC_CWIN_INITIAL|define +PICOQUIC_CWIN_MINIMUM|define +PICOQUIC_INITIAL_RTT" \
     "$P/picoquic/picoquic/"*.h 2>/dev/null | head
echo "  -- what the macros evaluate to:"
grep -rnE "define +PICOQUIC_MAX_PACKET_SIZE|define +PICOQUIC_INITIAL_MAX_PACKET" \
     "$P/picoquic/picoquic/"*.h 2>/dev/null | head -3

echo
echo "=== 3. What the window ACTUALLY did around the migration, per rep ==="
python3 - <<'PYEOF'
import csv, glob, os
R = "/home/sivaa/pvseed/results/raw/picoquic/reps"
INITIAL = 15360          # 10 x 1536, from picoquic's own source
for i in range(1, 6):
    f = f"{R}/rep_{i}/server_metrics.csv"
    if not os.path.exists(f):
        print(f"rep {i}: no csv"); continue
    rows = list(csv.DictReader(open(f)))
    def num(r, k):
        try: return float(r[k])
        except Exception: return None
    pts = [(num(r, "time_us"), num(r, "cwnd")) for r in rows if num(r, "cwnd") is not None]
    mig = 5_000_000
    # window immediately before migration, and the trajectory for 250 ms after
    before = [c for t, c in pts if t is not None and t < 4_980_000]
    after = [(t, c) for t, c in pts if t is not None and 4_980_000 <= t <= 5_260_000]
    exact_hits = [(t, c) for t, c in after if abs(c - INITIAL) < 1e-6]
    print(f"\nrep {i}:")
    print(f"  cwnd just before migration : {max(before[-50:]) if before else '?':>10,.0f} B"
          if before else "  no pre-migration samples")
    if after:
        lo = min(c for _, c in after); lo_t = [t for t, c in after if c == lo][0]
        print(f"  minimum in the 280 ms window: {lo:>10,.0f} B at t={lo_t:,.0f} us "
              f"({(lo_t - mig)/1000:+.0f} ms from migration)")
        print(f"  is that the 15,360 B initial window? {'YES' if abs(lo-INITIAL)<1e-6 else 'NO'}")
        print(f"  samples landing EXACTLY on 15,360 B: {len(exact_hits)}")
        # first sample at/after the migration instant
        first = [(t, c) for t, c in after if t >= mig][:1]
        if first:
            print(f"  first sample at/after t=5.000 s : {first[0][1]:,.0f} B")
PYEOF
