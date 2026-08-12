#!/usr/bin/env bash
# Re-run the corrected parser over all five repetitions.
P=/home/sivaa/pvseed
R=$P/results/raw/picoquic/reps
for i in 1 2 3 4 5; do
    SRV=$(ls -S "$R/rep_$i/qlog_server/"*.qlog 2>/dev/null | head -1)
    [ -n "$SRV" ] || { echo "rep $i: no qlog"; continue; }
    python3 "$P/analysis/parse_qlog.py" --qlog "$SRV" \
        --csv "$R/rep_$i/server_metrics.csv" --summary \
        > "$R/rep_$i/server_summary.txt" 2>&1
    echo "--- rep $i"
    grep -E "cwnd BEFORE|cwnd MIN|VERDICT|floor|packets lost near" \
         "$R/rep_$i/server_summary.txt"
done
