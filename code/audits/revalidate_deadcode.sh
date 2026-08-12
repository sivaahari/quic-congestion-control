#!/usr/bin/env bash
# EXHAUSTIVE re-validation of the claim:
#   "picoquic never dispatches picoquic_congestion_notification_reset"
#
# Previous checks used simple greps. This pass also hunts for INDIRECT dispatch
# (function pointers, macros, computed enum values, wrappers) that a naive grep
# would miss -- the most likely way the earlier finding could be wrong.
#
# IMPORTANT: this must run against PRISTINE upstream picoquic, not our modified
# tree (we added a caller ourselves in frames.c). We therefore check out a clean
# copy of the recorded upstream commit into a temp dir.
set -uo pipefail
PQ=/home/sivaa/pvseed/picoquic
CLEAN=/home/sivaa/pvseed/_build/picoquic_pristine

echo "=============================================================="
echo "0. Establish a PRISTINE upstream tree"
echo "=============================================================="
if [ ! -d "$CLEAN/.git" ]; then
    rm -rf "$CLEAN"
    git -C "$PQ" worktree list >/dev/null 2>&1
    git clone -q --no-checkout "$PQ" "$CLEAN" 2>/dev/null || {
        echo "  clone failed; falling back to in-place stash check"; }
fi
if [ -d "$CLEAN/.git" ]; then
    UPSTREAM=$(git -C "$PQ" rev-parse HEAD 2>/dev/null)
    git -C "$CLEAN" checkout -q "$UPSTREAM" 2>/dev/null && \
        echo "  pristine tree at commit $(git -C "$CLEAN" rev-parse --short HEAD)"
    TREE="$CLEAN"
else
    TREE="$PQ"
    echo "  WARNING: checking the MODIFIED tree; our own caller will appear."
fi

echo
echo "  our modifications vs upstream (should be the only diffs):"
git -C "$PQ" status --porcelain 2>/dev/null | head -10

echo
echo "=============================================================="
echo "1. Direct textual occurrences of the reset notification"
echo "=============================================================="
grep -rn "picoquic_congestion_notification_reset" "$TREE" \
    --include=*.c --include=*.h 2>/dev/null

echo
echo "=============================================================="
echo "2. EVERY alg_notify call site, with the notification passed"
echo "=============================================================="
grep -rn -A3 "alg_notify(" "$TREE" --include=*.c 2>/dev/null \
  | grep -oE "picoquic_congestion_notification_[a-z_]+" | sort | uniq -c | sort -rn

echo
echo "  -- raw call sites for manual inspection --"
grep -rn "alg_notify(" "$TREE" --include=*.c 2>/dev/null

echo
echo "=============================================================="
echo "3. INDIRECT dispatch hunt (how the finding could be wrong)"
echo "=============================================================="
echo "--- 3a. any variable holding a notification value? ---"
grep -rnE "picoquic_congestion_notification_t[[:space:]]+[a-zA-Z_]+" "$TREE" --include=*.c --include=*.h 2>/dev/null | head -20

echo
echo "--- 3b. macros that might expand to the reset enum ---"
grep -rnE "#define.*congestion_notification" "$TREE" --include=*.h 2>/dev/null || echo "  (none)"

echo
echo "--- 3c. computed/cast enum dispatch e.g. (picoquic_congestion_notification_t) ---"
grep -rn "(picoquic_congestion_notification_t)" "$TREE" --include=*.c 2>/dev/null || echo "  (none)"

echo
echo "--- 3d. wrappers around alg_notify ---"
grep -rnE "void .*notify.*\(picoquic_cnx_t" "$TREE/picoquic"/*.c "$TREE/picoquic"/*.h 2>/dev/null | head -10

echo
echo "--- 3e. is the enum value reachable numerically? print enum order ---"
grep -n -A16 "typedef enum.*{" "$TREE/picoquic/picoquic.h" 2>/dev/null \
  | grep -n -B2 -A16 "congestion_notification_acknowledgement" | head -30

echo
echo "=============================================================="
echo "4. What DOES run at path validation (the migration route)"
echo "=============================================================="
grep -n -A30 "picoquic_decode_path_response_frame" "$TREE/picoquic/frames.c" 2>/dev/null \
  | grep -E "challenge_verified|update_path_rtt|reset_path_mtu|alg_notify|cwin|first_tuple" | head -12

echo
echo "=============================================================="
echo "5. Every place cwin is assigned (is any on the migration path?)"
echo "=============================================================="
grep -rn "cwin *=" "$TREE/picoquic"/*.c 2>/dev/null | grep -v "==" | head -25

echo
echo "DONE"
