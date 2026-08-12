#!/usr/bin/env bash
# Publish Phase-1 deliverables to the Windows-side research folder.
set -uo pipefail
SRC=/home/sivaa/pvseed
DEST=/mnt/d/Users/Sivaa/Desktop/SEM-5/Computer-Networks/capstone-research/phase1-deliverables

mkdir -p "$DEST/figures"
cp -f "$SRC/paper/PhaseI_Review.pptx" "$DEST/"
cp -f "$SRC"/analysis/figures/v2_*.png "$DEST/figures/"
cp -f "$SRC"/analysis/figures/fig3_calibration_trap.png "$DEST/figures/" 2>/dev/null
cp -f "$SRC"/analysis/figures/fig4_train_length.png "$DEST/figures/" 2>/dev/null

# The animated HTML demo was discarded: it replayed only 15/11 sample points and
# conveyed nothing the static figure on slide 4 does not convey better.
rm -f "$DEST/demo.html" "$SRC/paper/demo.html"

echo "=== published ==="
find "$DEST" -type f -printf '%-70p %8s B\n' | sort
