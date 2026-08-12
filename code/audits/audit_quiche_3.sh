#!/usr/bin/env bash
# quiche audit part 3 -- the decisive mechanism question.
#
# HYPOTHESIS after part 2: quiche does NOT reset an existing controller. The
# 12,000 B we observe is a NEW Path object's fresh Recovery -- compliance by
# construction, not by reset. And its explicitly-named reset hook,
# on_connection_migration(), is dead code (marked #[allow(dead_code)]), exactly
# as picoquic's reset notification is.
set -uo pipefail
Q=/home/sivaa/pvseed/quiche/quiche/src

echo "=============================================================="
echo "1. Is on_connection_migration() EVER called? (the dead hook test)"
echo "=============================================================="
grep -rn "on_connection_migration" /home/sivaa/pvseed/quiche --include=*.rs 2>/dev/null
echo
echo "  -> occurrences that are DEFINITIONS/impls vs CALL SITES:"
grep -rn "on_connection_migration" /home/sivaa/pvseed/quiche --include=*.rs 2>/dev/null \
  | grep -vE "fn on_connection_migration|#\[allow" | grep -E "\.on_connection_migration\(" \
  || echo "     NO CALL SITES FOUND -- the hook is dead."

echo
echo "=============================================================="
echo "2. Does a NEW path get a brand-new Recovery? (Path::new)"
echo "=============================================================="
sed -n '231,272p' "$Q/path.rs" 2>/dev/null | grep -nE "fn new|recovery|Recovery::"

echo
echo "--- and where are new paths created on migration? ---"
grep -rn "Path::new\|create_path_on_client\|fn probe_path\|fn migrate\b\|fn migrate_source" \
    "$Q/lib.rs" 2>/dev/null | head -12

echo
echo "=============================================================="
echo "3. Default initial congestion window packets (expect 10)"
echo "=============================================================="
sed -n '650,662p' "$Q/lib.rs" 2>/dev/null
grep -rn "INITIAL_WINDOW_PACKETS" "$Q" --include=*.rs 2>/dev/null | head -6

echo
echo "=============================================================="
echo "4. Confirm the arithmetic: 10 x 1200 = 12000 (observed)"
echo "=============================================================="
grep -rn "const MAX_SEND_UDP_PAYLOAD_SIZE" "$Q/lib.rs" 2>/dev/null
echo "  observed cwnd at migration = 12,000 B"
echo "  minimum window = MINIMUM_WINDOW_PACKETS(2) x 1200 = 2,400 B"
echo "  cubic loss backoff = x BETA_CUBIC(0.7)"
echo "  -> a loss from a large cwnd cannot land on exactly 12,000; only fresh/initial state can."

echo
echo "=============================================================="
echo "5. What happens if the connection migrates BACK to an old path?"
echo "   (a path object that already exists retains its state)"
echo "=============================================================="
grep -rn -A6 "fn set_active_path" "$Q/lib.rs" 2>/dev/null | head -20

echo DONE
