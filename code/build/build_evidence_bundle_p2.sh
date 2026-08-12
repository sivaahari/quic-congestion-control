#!/usr/bin/env bash
# Assemble the Phase-2 evidence bundle.
# The full raw dataset is many GB of qlog; this copies the artefacts that
# actually EVIDENCE the survey, plus one representative trace per stack.
set -uo pipefail
P=/home/sivaa/pvseed
OUT=/mnt/d/Users/Sivaa/Desktop/SEM-5/Computer-Networks/capstone-research/phase2-deliverables/evidence

rm -rf "$OUT"
mkdir -p "$OUT"/{01_survey_data,02_source_audits,03_live_measurements,04_validation,05_code,06_sample_traces}

echo "=== 01 survey data (the single source of truth) ==="
cp -f "$P/analysis/survey_results.json" "$OUT/01_survey_data/"
python3 - "$P/analysis/survey_results.json" "$OUT/01_survey_data/survey_table.csv" <<'PYEOF'
import csv, json, sys
d = json.load(open(sys.argv[1]))
with open(sys.argv[2], "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["implementation","language","commit","q1","q1_mechanism","q2","q3",
                "reset_hook","hook_callers","hook_dead","initial_cwnd_B","min_cwnd_B",
                "loss_factor","live_reps","cwnd_before_B","cwnd_after_B","reset_observed"])
    for i in d["implementations"]:
        rh = i.get("reset_hook") or {}
        lv = i.get("live") or {}
        w.writerow([i["name"], i["language"], i.get("commit",""),
                    i["q1"]["answer"], i["q1"].get("mechanism","")[:120],
                    i["q2"]["answer"], i["q3"]["answer"],
                    rh.get("name",""), rh.get("callers",""), rh.get("dead",""),
                    i.get("initial_cwnd_bytes",""), i.get("min_cwnd_bytes",""),
                    i.get("loss_factor",""), lv.get("reps",""),
                    lv.get("cwnd_before_bytes",""), lv.get("cwnd_after_bytes",""),
                    lv.get("reset_observed","")])
print("  wrote survey_table.csv")
PYEOF
ls -1 "$OUT/01_survey_data/"

echo
echo "=== 02 source audits (re-runnable) ==="
for f in revalidate_pristine.sh revalidate_deadcode.sh audit_quicgo.sh \
         audit_quiche_1.sh audit_quiche_2.sh audit_quiche_3.sh \
         audit_msquic_1.sh audit_msquic_2.sh \
         audit_ngtcp2_1.sh audit_ngtcp2_2.sh audit_ngtcp2_3.sh audit_ngtcp2_4.sh; do
    [ -f "$P/_build/$f" ] && cp -f "$P/_build/$f" "$OUT/02_source_audits/"
done
ls -1 "$OUT/02_source_audits/" | wc -l | xargs echo "  scripts:"

echo
echo "=== 03 live measurements (derived CSVs, one per stack) ==="
mkdir -p "$OUT/03_live_measurements"/{quicgo,quiche,msquic,ngtcp2,picoquic}
for i in 1 2 3 4 5; do
    # picoquic: five repetitions at the standard operating point, restoring
    # parity with the other four. The Phase-1 single run at 50 Mbit is retained
    # in the project tree but superseded.
    cp -f "$P/results/raw/picoquic/reps/rep_$i/server_metrics.csv" \
          "$OUT/03_live_measurements/picoquic/rep${i}_server.csv" 2>/dev/null
    cp -f "$P/results/raw/picoquic/reps/rep_$i/server_summary.txt" \
          "$OUT/03_live_measurements/picoquic/rep${i}_summary.txt" 2>/dev/null
    cp -f "$P/results/raw/quicgo/repeat/rep$i/server_metrics.csv" \
          "$OUT/03_live_measurements/quicgo/rep${i}_server.csv" 2>/dev/null
    cp -f "$P/results/raw/quiche/migrate_demo/rep_$i/server_metrics.csv" \
          "$OUT/03_live_measurements/quiche/rep${i}_server.csv" 2>/dev/null
    cp -f "$P/results/raw/msquic/migrate_demo/rep_$i/server_metrics.csv" \
          "$OUT/03_live_measurements/msquic/rep${i}_server.csv" 2>/dev/null
    cp -f "$P/results/raw/msquic/migrate_demo/rep_$i/client_metrics.csv" \
          "$OUT/03_live_measurements/msquic/rep${i}_client.csv" 2>/dev/null
    # ngtcp2's example client logged every packet: ~445 MB per run. Only the
    # migration evidence was ever shipped, and the giant logs were removed by
    # _build/cleanup_project.sh -- which extracted those lines to
    # client_migration_evidence.txt FIRST. Prefer that extract; fall back to the
    # raw log if someone re-runs the trial and it exists again.
    RAW="$P/results/raw/ngtcp2/reps/rep_$i/client.log"
    PRE="$P/results/raw/ngtcp2/reps/rep_$i/client_migration_evidence.txt"
    DST="$OUT/03_live_measurements/ngtcp2/rep${i}_migration_evidence.txt"
    if [ -f "$RAW" ]; then
        {
            echo "# extract from client.log ($(stat -c%s "$RAW") bytes)"
            echo "# only migration evidence is shipped, not the whole trace"
            grep -aiE "Changing local address|Local address is now|path validation|migrat" \
                 "$RAW" 2>/dev/null | head -40
        } > "$DST"
    elif [ -s "$PRE" ]; then
        cp -f "$PRE" "$DST"
    else
        echo "  WARNING: no ngtcp2 migration evidence for rep $i" >&2
    fi
done
cp -f "$P/results/raw/quiche/migrate_demo/rep_"*/server_summary.txt "$OUT/03_live_measurements/quiche/" 2>/dev/null
cp -f "$P/results/raw/msquic/migrate_demo/rep_status.txt" "$OUT/03_live_measurements/msquic/" 2>/dev/null
find "$OUT/03_live_measurements" -type f | wc -l | xargs echo "  files:"

echo
echo "=== 04 validation (the independent re-derivation) ==="
cp -f "$P/_validation/revalidate_fresh.py" "$OUT/04_validation/"
cp -f "$P/_validation/recheck_f6.py" "$OUT/04_validation/" 2>/dev/null
cd "$P" && python3 _validation/revalidate_fresh.py > "$OUT/04_validation/validation_run_output.txt" 2>&1
tail -3 "$OUT/04_validation/validation_run_output.txt"

echo
echo "=== 05 code (the apparatus) ==="
mkdir -p "$OUT/05_code"/{testbed,analysis,harness}
# SOURCE ONLY. An earlier version used `cp -rf` on whole directories and pulled
# in compiled binaries, Go/Rust build trees and Cargo caches -- a 2.2 GB bundle.
# Copy by extension instead, and never anything executable.
find "$P/testbed" -type f \( -name '*.sh' -o -name '*.py' -o -name '*.json' \) \
    -exec cp -f {} "$OUT/05_code/testbed/" \; 2>/dev/null
cp -f "$P"/analysis/*.py "$OUT/05_code/analysis/" 2>/dev/null
cp -f "$P/harness/migrate_client.c" "$OUT/05_code/harness/" 2>/dev/null
for f in "$P"/harness/quicgo/{server,client}/main.go; do
    [ -f "$f" ] && cp -f "$f" "$OUT/05_code/harness/quicgo_$(basename "$(dirname "$f")")_main.go"
done
find "$P/harness/msquic" -maxdepth 1 -type f \( -name '*.cpp' -o -name '*.h' -o -name '*.sh' \) \
    -exec cp -f {} "$OUT/05_code/harness/" \; 2>/dev/null
git -C "$P/picoquic" diff HEAD > "$OUT/05_code/picoquic_our_changes.diff" 2>/dev/null
{
  echo "picoquic  $(git -C "$P/picoquic" rev-parse HEAD 2>/dev/null)"
  echo "quic-go   $(git -C "$P/quic-go" rev-parse HEAD 2>/dev/null)"
  echo "quiche    $(git -C "$P/quiche" rev-parse HEAD 2>/dev/null)"
  echo "msquic    $(git -C "$P/msquic" rev-parse HEAD 2>/dev/null)"
  echo "ngtcp2    $(git -C "$P/ngtcp2" rev-parse HEAD 2>/dev/null)"
} > "$OUT/05_code/commit_hashes.txt"
cat "$OUT/05_code/commit_hashes.txt"

echo
echo "=== 06 sample traces (one per stack, gzipped) ==="
gz() { [ -f "$1" ] && gzip -c "$1" > "$OUT/06_sample_traces/$2.gz"; }
# Sample from the CURRENT five repetitions, not the superseded Phase-1 run --
# a reviewer opening the sample trace should be opening the measurement we report.
gz "$(ls -S "$P"/results/raw/picoquic/reps/rep_*/qlog_server/*.qlog 2>/dev/null | head -1)" picoquic_server.qlog
gz "$(ls -S "$P"/results/raw/quicgo/migrate_demo/qlog_server/*.sqlog 2>/dev/null | head -1)" quicgo_server.sqlog
gz "$(ls -S "$P"/results/raw/quiche/migrate_demo/rep_1/qlog_server/*.sqlog 2>/dev/null | head -1)" quiche_server.sqlog
gz "$(ls -S "$P"/results/raw/ngtcp2/reps/rep_1/qlog_server/*.sqlog 2>/dev/null | head -1)" ngtcp2_server.sqlog
cp -f "$P/results/raw/msquic/migrate_demo/rep_1/server.log" "$OUT/06_sample_traces/msquic_server.log" 2>/dev/null
gzip -f "$OUT/06_sample_traces/msquic_server.log" 2>/dev/null
ls -lh "$OUT/06_sample_traces/" | tail -6

echo
echo "=============================================="
echo "BUNDLE: $(du -sh "$OUT" | cut -f1)  ·  $(find "$OUT" -type f | wc -l) files"
echo "=============================================="
