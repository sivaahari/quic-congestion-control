#!/usr/bin/env bash
# Publish Phase-2 deliverables to the Windows-side research folder.
#
# The Phase-1 script (publish_deliverables.sh) is hardcoded to PhaseI_Review.pptx
# and v2_*.png, so it never carried the Phase-2 deck across. The Phase-2 figures
# had been copied by an ad-hoc `cp` BEFORE the final regeneration, leaving two
# stale files on the Windows side. Hence this script: one command, no drift.
set -uo pipefail
SRC=/home/sivaa/pvseed
DEST=/mnt/d/Users/Sivaa/Desktop/SEM-5/Computer-Networks/capstone-research/phase2-deliverables

mkdir -p "$DEST/figures"
cp -f "$SRC/paper/PhaseII_Review.pptx" "$DEST/"
cp -f "$SRC"/analysis/figures/p2_fig*.png "$DEST/figures/"

echo "=== published ==="
find "$DEST" -maxdepth 2 -type f -not -path "*/evidence/*" -printf '%-78p %9s B\n' | sort

# The deck embeds the figures at build time. If a figure on disk is newer than
# the deck, the deck is stale and must be rebuilt before the copy means anything.
echo
echo "=== staleness check (deck vs the figures it embeds) ==="
DECK="$SRC/paper/PhaseII_Review.pptx"
stale=0
for f in "$SRC"/analysis/figures/p2_fig*.png; do
    [ "$f" -nt "$DECK" ] && { echo "  STALE: $(basename "$f") is newer than the deck"; stale=1; }
done
[ "$stale" -eq 0 ] && echo "  OK - deck is newer than every figure it embeds"

# Stronger than mtime: confirm the bytes inside the .pptx are the bytes on disk.
python3 - "$DECK" "$SRC/analysis/figures" <<'PYEOF'
import hashlib, sys, zipfile, pathlib
deck, figdir = sys.argv[1], pathlib.Path(sys.argv[2])
z = zipfile.ZipFile(deck)
embedded = {hashlib.md5(z.read(n)).hexdigest()
            for n in z.namelist() if n.startswith("ppt/media/")}
print("\n=== content check (md5 of embedded images vs figures on disk) ===")
bad = 0
for f in sorted(figdir.glob("p2_fig*.png")):
    h = hashlib.md5(f.read_bytes()).hexdigest()
    ok = h in embedded
    bad += not ok
    print(f"  {'OK  ' if ok else 'MISS'} {f.name}  {h}")
print(f"  slides: {sum(1 for n in z.namelist() if n.startswith('ppt/slides/slide') and n.endswith('.xml'))}")
sys.exit(1 if bad else 0)
PYEOF
