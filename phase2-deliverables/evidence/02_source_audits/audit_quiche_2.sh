#!/usr/bin/env bash
# quiche audit part 2 -- what does on_path_change DO, and when does it fire?
set -uo pipefail
Q=/home/sivaa/pvseed/quiche/quiche/src

echo "=============================================================="
echo "1. The trait declaration + doc comment"
echo "=============================================================="
sed -n '95,120p' "$Q/recovery/gcongestion/mod.rs" 2>/dev/null
echo "--- recovery/mod.rs trait entry ---"
sed -n '225,245p' "$Q/recovery/mod.rs" 2>/dev/null

echo
echo "=============================================================="
echo "2. The classic (non-gcongestion) implementation"
echo "=============================================================="
awk '/fn on_path_change\(/{f=1} f{print NR": "$0} f&&/^    }/{exit}' \
    "$Q/recovery/congestion/recovery.rs" 2>/dev/null | head -40

echo
echo "=============================================================="
echo "3. The gcongestion implementation"
echo "=============================================================="
awk '/fn on_path_change\(/{f=1} f{print NR": "$0} f&&/^    }/{exit}' \
    "$Q/recovery/gcongestion/recovery.rs" 2>/dev/null | head -40

echo
echo "=============================================================="
echo "4. THE CALL SITE -- what event triggers it? (lib.rs:9139)"
echo "=============================================================="
sed -n '9100,9150p' "$Q/lib.rs" 2>/dev/null

echo
echo "=============================================================="
echo "5. Default initial congestion window packets"
echo "=============================================================="
grep -rn "initial_congestion_window_packets" "$Q/lib.rs" "$Q/recovery/mod.rs" 2>/dev/null | head -8
grep -rn "INITIAL_WINDOW_PACKETS\|initial_congestion_window_packets: *[0-9]" "$Q" --include=*.rs 2>/dev/null | head -6

echo
echo "=============================================================="
echo "6. Does a NEW path get fresh recovery state? (Path::new)"
echo "=============================================================="
sed -n '225,275p' "$Q/path.rs" 2>/dev/null

echo DONE
