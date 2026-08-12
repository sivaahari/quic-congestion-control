#!/usr/bin/env bash
# cleanup_project2.sh -- second pass, after cleanup_project.sh.
#
# The distinction that matters here: DELETE what nothing reads, COMPRESS what
# something still reads. results/raw/baseline is Phase-1's primary dataset and is
# referenced by analysis/build_baseline_dataset.py and analysis/make_figures.py,
# so it is gzipped rather than destroyed -- qlog is JSON and compresses about
# ten to one.
#
# Still never touched: any qlog/sqlog under the five surveyed rep directories or
# _task2_verify, because the independent validator re-parses those.
set -uo pipefail
P=/home/sivaa/pvseed
DRY="${DRY_RUN:-0}"
before=$(du -sm "$P" 2>/dev/null | cut -f1)

say()  { printf '\n=== %s ===\n' "$1"; }
zap() {
    [ -e "$1" ] || return 0
    local sz; sz=$(du -sh "$1" 2>/dev/null | cut -f1)
    if [ "$DRY" = "1" ]; then printf '  would delete %-52s %8s\n' "$1" "$sz"
    else rm -rf "$1" && printf '  deleted %-57s %8s\n' "$1" "$sz"; fi
}

say "1. msquic submodules -- needed only to BUILD, not to audit"
# The audits read msquic/src/core. Restoring these is one command:
#   git -C msquic submodule update --init --recursive
zap "$P/msquic/submodules"

say "2. exploratory and superseded run trees"
zap "$P/results/raw/quiche/diag_run1"
zap "$P/results/raw/quiche/smoke"
zap "$P/results/raw/ngtcp2/trial1"

say "3. ngtcp2 per-run server logs (not read by validator or bundle)"
if [ "$DRY" = "1" ]; then
    find "$P/results/raw/ngtcp2" -name 'server.log' -printf '%s\n' 2>/dev/null \
      | awk '{s+=$1;n++} END{printf "  would delete %d files, %.0f MB\n", n, s/1048576}'
else
    n=$(find "$P/results/raw/ngtcp2" -name 'server.log' 2>/dev/null | wc -l)
    find "$P/results/raw/ngtcp2" -name 'server.log' -delete 2>/dev/null
    printf '  deleted %d ngtcp2 server.log files\n' "$n"
fi

say "4. python bytecode caches"
if [ "$DRY" = "1" ]; then
    find "$P" -type d -name __pycache__ 2>/dev/null | sed 's/^/  would delete /' | head -5
else
    find "$P" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null
    echo "  __pycache__ removed"
fi

say "5. COMPRESS Phase-1 baseline (referenced by analysis scripts -- kept, not deleted)"
b="$P/results/raw/baseline"
if [ -d "$b" ]; then
    sz_before=$(du -sh "$b" | cut -f1)
    if [ "$DRY" = "1" ]; then
        echo "  would gzip every .qlog/.log under $b (currently $sz_before)"
    else
        find "$b" -type f \( -name '*.qlog' -o -name '*.log' \) ! -name '*.gz' \
             -exec gzip -6 {} + 2>/dev/null
        echo "  $sz_before -> $(du -sh "$b" | cut -f1)  (gzip; readers must gunzip first)"
    fi
fi

after=$(du -sm "$P" 2>/dev/null | cut -f1)
say "result"
printf '  before %6.2f GB   after %6.2f GB   reclaimed %6.2f GB\n' \
    "$(echo "$before/1024" | bc -l)" "$(echo "$after/1024" | bc -l)" \
    "$(echo "($before-$after)/1024" | bc -l)"
