#!/usr/bin/env bash
set -uo pipefail
D=/mnt/d/Users/Sivaa/Desktop/SEM-5/Computer-Networks/capstone-research/phase2-deliverables/evidence

echo "=== per-directory ==="
for d in "$D"/*/; do
    [ -d "$d" ] || continue
    n=$(find "$d" -type f 2>/dev/null | wc -l)
    b=$(find "$d" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{printf "%.1f", s/1048576}')
    printf "  %-28s %4s files  %8s MB\n" "$(basename "$d")" "$n" "$b"
done

echo
echo "=== files over 20 MB ==="
find "$D" -type f -size +20M -printf '%10s  %P\n' 2>/dev/null | sort -rn | head -10 \
  || echo "  (none)"

echo
echo "=== true total ==="
find "$D" -type f -printf '%s\n' 2>/dev/null \
  | awk '{s+=$1; n++} END{printf "  %d files, %.1f MB\n", n, s/1048576}'
