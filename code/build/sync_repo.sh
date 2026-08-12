#!/usr/bin/env bash
# Populate the Windows-side git working tree from the WSL project tree.
#
# The apparatus lives in WSL (/home/sivaa/pvseed, 22 GB including cloned
# upstreams, build trees and ~16 GB of raw qlog). The repository must carry the
# SOURCE and the derived evidence only. Copying by hand once would guarantee
# drift, which is exactly how two figures went stale earlier in this project --
# so this is a script, and it is itself committed.
#
# NOT copied, deliberately:
#   picoquic/ quiche/ msquic/ ngtcp2/ quic-go/ picotls/ nghttp3/  (upstream, pinned by commit)
#   results/                                                       (~16 GB raw qlog)
#   build trees, binaries, logs
set -uo pipefail
P=/home/sivaa/pvseed
R=/mnt/d/Users/Sivaa/Desktop/SEM-5/Computer-Networks/capstone-research

say() { printf '\n=== %s ===\n' "$1"; }

mkdir -p "$R"/code/{analysis,testbed,harness,audits,validation,qa,build,patches} "$R"/data

say "data (the single source of truth)"
cp -f "$P/analysis/survey_results.json" "$R/data/"
ls -1 "$R/data/"

say "analysis (figure + deck generators, qlog parsers)"
for f in "$P"/analysis/*.py; do cp -f "$f" "$R/code/analysis/"; done
ls -1 "$R/code/analysis/" | wc -l | xargs echo "  files:"

say "testbed (topology, shaping, calibration, scenarios)"
for sub in topology shaping calibration scenarios; do
    mkdir -p "$R/code/testbed/$sub"
    find "$P/testbed/$sub" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' -o -name '*.json' \) \
        -exec cp -f {} "$R/code/testbed/$sub/" \; 2>/dev/null
done
find "$R/code/testbed" -type f | wc -l | xargs echo "  files:"

say "harness (our own clients and servers)"
cp -f "$P/harness/migrate_client.c" "$R/code/harness/" 2>/dev/null
for f in "$P"/harness/msquic/*.cpp "$P"/harness/msquic/*.h "$P"/harness/msquic/*.sh; do
    [ -f "$f" ] && cp -f "$f" "$R/code/harness/msquic_$(basename "$f")"
done
for d in client server; do
    f="$P/harness/quicgo/$d/main.go"
    [ -f "$f" ] && cp -f "$f" "$R/code/harness/quicgo_${d}_main.go"
done
for f in "$P"/harness/quiche/src/bin/*.rs; do
    [ -f "$f" ] && cp -f "$f" "$R/code/harness/quiche_$(basename "$f")"
done
ls -1 "$R/code/harness/" | wc -l | xargs echo "  files:"

say "audits (the source-side evidence)"
for f in "$P"/_build/audit_*.sh "$P"/_build/revalidate_*.sh "$P"/_build/check_rtt_after_reset.sh \
         "$P"/_build/extract_pv_rtt.sh "$P"/_build/analyze_migration_qlog.py; do
    [ -f "$f" ] && cp -f "$f" "$R/code/audits/"
done
ls -1 "$R/code/audits/" | wc -l | xargs echo "  files:"

say "validation (independent re-derivation)"
cp -f "$P"/_validation/*.py "$R/code/validation/" 2>/dev/null
cp -f "$P/_validation/check_json_and_revalidate.sh" "$R/code/validation/" 2>/dev/null
# Ship the run output as the record of the result, not just the code.
( cd "$P" && python3 _validation/revalidate_fresh.py ) \
    > "$R/code/validation/validation_run_output.txt" 2>&1
tail -3 "$R/code/validation/validation_run_output.txt"

say "qa (deliverable verification)"
for f in deck_geometry_qa.py deck_content_qa.py render_deck.sh rebuild_and_render.sh \
         install_renderer.sh \
         picoquic_ground_truth.py picoquic_rtt.py picoquic_after.py \
         picoquic_discriminate.sh picoquic_reparse.sh; do
    cp -f "$P/_qa/$f" "$R/code/qa/" 2>/dev/null
done
cp -f "$P/_validation/run_validator.sh" "$R/code/validation/" 2>/dev/null
ls -1 "$R/code/qa/" | wc -l | xargs echo "  files:"

say "build (environment setup, bundling, publishing)"
for f in "$P"/_build/0*.sh "$P"/_build/1*.sh "$P"/_build/2*.sh "$P"/_build/3*.py \
         "$P"/_build/build_evidence_bundle*.sh "$P"/_build/publish_deliverables*.sh \
         "$P"/_build/bundle_size_check.sh "$P"/_build/sync_repo.sh \
         "$P"/_build/evidence_inventory.sh "$P"/_build/quicgo_repeat2.sh \
         "$P"/_build/cleanup_project*.sh; do
    [ -f "$f" ] && cp -f "$f" "$R/code/build/"
done
ls -1 "$R/code/build/" | wc -l | xargs echo "  files:"

say "patches (our own change to picoquic)"
git -C "$P/picoquic" diff HEAD > "$R/code/patches/picoquic_spec_reset.diff" 2>/dev/null
wc -c < "$R/code/patches/picoquic_spec_reset.diff" | xargs echo "  diff bytes:"

say "pinned upstream commits"
{
  echo "# The five surveyed implementations, at the commit each was audited and measured at."
  echo "# Clone these to reproduce; nothing upstream is vendored into this repository."
  echo
  printf '%-10s %-46s %s\n' IMPLEMENTATION COMMIT UPSTREAM
  printf '%-10s %-46s %s\n' picoquic "$(git -C "$P/picoquic" rev-parse HEAD 2>/dev/null)" https://github.com/private-octopus/picoquic
  printf '%-10s %-46s %s\n' quic-go  "$(git -C "$P/quic-go"  rev-parse HEAD 2>/dev/null)" https://github.com/quic-go/quic-go
  printf '%-10s %-46s %s\n' quiche   "$(git -C "$P/quiche"   rev-parse HEAD 2>/dev/null)" https://github.com/cloudflare/quiche
  printf '%-10s %-46s %s\n' msquic   "$(git -C "$P/msquic"   rev-parse HEAD 2>/dev/null)" https://github.com/microsoft/msquic
  printf '%-10s %-46s %s\n' ngtcp2   "$(git -C "$P/ngtcp2"   rev-parse HEAD 2>/dev/null)" https://github.com/ngtcp2/ngtcp2
} > "$R/data/upstream_commits.txt"
cat "$R/data/upstream_commits.txt"

say "summary"
find "$R/code" "$R/data" -type f | wc -l | xargs echo "  files synced:"
du -sh "$R/code" "$R/data" | sed 's/^/  /'
