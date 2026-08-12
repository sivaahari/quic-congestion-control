#!/usr/bin/env bash
# cleanup_project.sh -- reclaim disk without losing anything load-bearing.
#
# WHAT IS LOAD-BEARING, and therefore never touched:
#   * every qlog/sqlog under the five surveyed rep directories and _task2_verify
#     -- the independent validator RE-PARSES these, so deleting them would make
#     "30/30 checks pass" unreproducible
#   * every .csv / .txt / summary under results/  -- the derived evidence
#   * all source: analysis/ testbed/ harness/*.{c,go,rs,cpp,h} _validation/ _qa/
#     and the .sh/.py in _build/
#   * paper/ -- the decks
#   * anything on /mnt/d -- the Windows-side git working tree
#
# WHAT GOES, and why it is safe:
#   1. transferred payload (*.bin) -- the file each trial downloads plus its
#      copy. 10.1 GB of it. Pure ballast; no tool reads it.
#   2. baseline_v1_contaminated -- superseded by the v2 dataset; the directory
#      name records why.
#   3. exploratory/superseded run trees from Phase 1 (_migrate_demo, _taskA_*,
#      quicgo/_smoke, _build/smoke*, _build/_fake_baseline).
#   4. ngtcp2 client.log -- ~445 MB per run. The evidence lines are extracted to
#      a small file FIRST, and the bundle already ships those extracts.
#   5. build trees. Reproducible from the pinned commits via code/build/*.sh.
#      picoquicdemo and migrate_client are preserved so picoquic trials still
#      run without a rebuild.
#
# Pass DRY_RUN=1 to list without deleting.
set -uo pipefail
P=/home/sivaa/pvseed
DRY="${DRY_RUN:-0}"

before=$(du -sm "$P" 2>/dev/null | cut -f1)
say()  { printf '\n=== %s ===\n' "$1"; }
gone() { printf '  %-58s %8s\n' "$1" "$2"; }

zap() {  # zap <path>
    [ -e "$1" ] || return 0
    local sz; sz=$(du -sh "$1" 2>/dev/null | cut -f1)
    if [ "$DRY" = "1" ]; then gone "would delete: $1" "$sz"; else
        rm -rf "$1" && gone "deleted: $1" "$sz"
    fi
}

say "0. preserve ngtcp2 migration evidence before removing the giant logs"
for d in "$P"/results/raw/ngtcp2/reps/rep_* "$P"/results/raw/ngtcp2/trial1; do
    [ -f "$d/client.log" ] || continue
    out="$d/client_migration_evidence.txt"
    if [ ! -s "$out" ]; then
        {
            echo "# extracted from client.log ($(stat -c%s "$d/client.log") bytes) before deletion"
            echo "# the full log is ~445 MB of per-packet tracing; only migration evidence is kept"
            grep -aiE "Changing local address|Local address is now|path validation|migrat" \
                 "$d/client.log" 2>/dev/null | head -60
        } > "$out"
    fi
    printf '  %s -> %s bytes\n' "$(basename "$d")" "$(stat -c%s "$out" 2>/dev/null)"
done

say "1. transferred payload (.bin) -- 10.1 GB of ballast"
if [ "$DRY" = "1" ]; then
    find "$P/results" -type f -name '*.bin' -printf '%s\n' 2>/dev/null \
      | awk '{s+=$1; n++} END{printf "  would delete %d files, %.1f GB\n", n, s/1073741824}'
else
    n=$(find "$P/results" -type f -name '*.bin' 2>/dev/null | wc -l)
    find "$P/results" -type f -name '*.bin' -delete 2>/dev/null
    gone "deleted $n payload .bin files" "~10 GB"
fi

say "2. superseded and exploratory datasets"
zap "$P/results/raw/baseline_v1_contaminated"
zap "$P/results/raw/_migrate_demo"
zap "$P/results/raw/_taskA_repro"
zap "$P/results/raw/_taskA_portcheck"
zap "$P/results/raw/quicgo/_smoke"
zap "$P/_build/smoke"
zap "$P/_build/smoke2"
zap "$P/_build/smoke3"
zap "$P/_build/_fake_baseline"

say "3. oversized per-packet client logs (evidence extracted in step 0)"
for d in "$P"/results/raw/ngtcp2/reps/rep_* "$P"/results/raw/ngtcp2/trial1; do
    zap "$d/client.log"
done

say "4. build trees (reproducible; picoquic binaries preserved)"
# Keep picoquicdemo at the path run_migration_trial.sh expects, so picoquic
# trials remain runnable with no rebuild.
if [ -x "$P/picoquic/build/picoquicdemo" ] && [ "$DRY" != "1" ]; then
    cp -f "$P/picoquic/build/picoquicdemo" "$P/picoquicdemo.keep"
fi
zap "$P/picoquic/build"
if [ -f "$P/picoquicdemo.keep" ] && [ "$DRY" != "1" ]; then
    mkdir -p "$P/picoquic/build"
    mv -f "$P/picoquicdemo.keep" "$P/picoquic/build/picoquicdemo"
    chmod +x "$P/picoquic/build/picoquicdemo"
    echo "  preserved: picoquic/build/picoquicdemo ($(du -h "$P/picoquic/build/picoquicdemo" | cut -f1))"
fi
zap "$P/quiche/target"
zap "$P/msquic/build"
zap "$P/ngtcp2/build"
zap "$P/harness/quiche/target"
zap "$P/harness/quicgo/pkg"
zap "$P/harness/migrate_client.o"

say "5. stray outputs left inside the cloned repositories"
for f in "$P"/picoquic/*.qlog "$P"/picoquic/*.client.log "$P"/picoquic/*.server.log \
         "$P"/picoquic/*.server.qlog; do
    zap "$f"
done

say "6. package cache (outside the project, safe to drop)"
if [ "$DRY" = "1" ]; then
    du -sh /var/cache/apt/archives 2>/dev/null | sed 's/^/  would clean: /'
else
    apt-get clean >/dev/null 2>&1 && echo "  apt cache cleaned"
fi

after=$(du -sm "$P" 2>/dev/null | cut -f1)
say "result"
printf '  project before : %6.1f GB\n' "$(echo "$before/1024" | bc -l)"
printf '  project after  : %6.1f GB\n' "$(echo "$after/1024" | bc -l)"
printf '  reclaimed      : %6.1f GB\n' "$(echo "($before-$after)/1024" | bc -l)"
