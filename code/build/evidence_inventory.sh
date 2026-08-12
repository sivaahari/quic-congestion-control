#!/usr/bin/env bash
# Inventory every artefact that could serve as evidence of experiments run.
set -uo pipefail
P=/home/sivaa/pvseed

echo "############ PROCESSED CSVs (headline evidence) ############"
for f in "$P"/results/processed/*.csv; do
    [ -f "$f" ] || continue
    printf "%-58s %8s B  %5s rows\n" "${f#$P/}" "$(stat -c%s "$f")" "$(( $(wc -l < "$f") - 1 ))"
done

echo
echo "############ RAW CSVs ############"
for f in "$P"/results/raw/*.csv; do
    [ -f "$f" ] || continue
    printf "%-58s %8s B  %5s rows\n" "${f#$P/}" "$(stat -c%s "$f")" "$(( $(wc -l < "$f") - 1 ))"
done

echo
echo "############ qlog TRACES (per-connection protocol logs) ############"
find "$P/results/raw" -name '*.qlog' -printf '%s %p\n' 2>/dev/null | sort -rn | head -20 \
  | while read -r sz path; do printf "%-72s %10s B\n" "${path#$P/}" "$sz"; done
echo "  total qlog files: $(find "$P/results/raw" -name '*.qlog' 2>/dev/null | wc -l)"
echo "  total qlog bytes: $(find "$P/results/raw" -name '*.qlog' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s}')"

echo
echo "############ JSON (dispersion measurements) ############"
find "$P/results" -name '*.json' -printf '%s %p\n' 2>/dev/null | sort -rn | head -10 \
  | while read -r sz path; do printf "%-72s %10s B\n" "${path#$P/}" "$sz"; done
echo "  total json files: $(find "$P/results" -name '*.json' 2>/dev/null | wc -l)"

echo
echo "############ TEST / BUILD LOGS ############"
find "$P/results/raw" -maxdepth 1 -name '*.log' -o -maxdepth 1 -name '*.txt' 2>/dev/null \
  | sort | while read -r f; do printf "%-58s %10s B\n" "${f#$P/}" "$(stat -c%s "$f")"; done

echo
echo "############ EXPERIMENT DIRECTORIES ############"
for d in "$P"/results/raw/*/; do
    [ -d "$d" ] || continue
    printf "%-52s %4s files\n" "${d#$P/}" "$(find "$d" -type f | wc -l)"
done

echo
echo "############ BASELINE TRIAL TREE ############"
find "$P/results/raw/baseline" -maxdepth 3 -type d 2>/dev/null | sort | sed "s|$P/||" | head -30

echo
echo "############ SCRIPTS (the experiment itself) ############"
find "$P/testbed" "$P/analysis" "$P/harness" -type f \( -name '*.sh' -o -name '*.py' -o -name '*.c' \) 2>/dev/null \
  | sort | while read -r f; do printf "%-62s %8s B\n" "${f#$P/}" "$(stat -c%s "$f")"; done

echo
echo "############ SOURCE MODIFICATIONS ############"
git -C "$P/picoquic" diff --stat HEAD 2>/dev/null | tail -5
echo "  upstream commit: $(git -C "$P/picoquic" rev-parse HEAD 2>/dev/null)"
echo "DONE"
