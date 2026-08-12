#!/usr/bin/env bash
# Render every slide of the Phase-2 deck to a JPEG for visual inspection.
# Output goes to the Windows side so the images can be viewed directly.
set -x
DECK=/home/sivaa/pvseed/paper/PhaseII_Review.pptx
OUT=/mnt/c/Users/Sivaa/AppData/Local/Temp/claude/D--Users-Sivaa-Desktop-SEM-5-Computer-Networks-capstone-research/cf39cd64-b33d-492d-83c6-9bb90fdbb90a/scratchpad/deckrender

rm -rf "$OUT"
mkdir -p "$OUT"
cd "$OUT" || exit 1

# HOME must be writable or LibreOffice refuses to start in this environment.
export HOME=/root
soffice --headless --norestore --convert-to pdf --outdir "$OUT" "$DECK"
ls -la "$OUT"
pdftoppm -jpeg -r 110 "$OUT/PhaseII_Review.pdf" "$OUT/slide"
ls -1 "$OUT"/slide-*.jpg | wc -l
