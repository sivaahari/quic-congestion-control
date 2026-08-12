#!/usr/bin/env bash
# Decisive check against PRISTINE upstream, read straight out of git object
# storage (git show HEAD:<path>) so our own edits cannot contaminate it.
set -uo pipefail
PQ=/home/sivaa/pvseed/picoquic
W=/home/sivaa/pvseed/_build/pristine_src
mkdir -p "$W"

echo "=============================================================="
echo "0. Confirm what WE changed vs upstream"
echo "=============================================================="
git -C "$PQ" rev-parse HEAD
echo "--- files we modified ---"
git -C "$PQ" diff --stat HEAD 2>/dev/null
echo "--- untracked ---"
git -C "$PQ" status --porcelain 2>/dev/null | grep '^??' | head

echo
echo "=============================================================="
echo "1. Extract PRISTINE copies of every .c/.h in picoquic/"
echo "=============================================================="
rm -rf "$W"; mkdir -p "$W"
git -C "$PQ" ls-tree -r --name-only HEAD -- picoquic \
  | grep -E '\.(c|h)$' > "$W/filelist.txt"
echo "  $(wc -l < "$W/filelist.txt") source files"
while read -r f; do
    mkdir -p "$W/$(dirname "$f")"
    git -C "$PQ" show "HEAD:$f" > "$W/$f" 2>/dev/null
done < "$W/filelist.txt"

echo
echo "=============================================================="
echo "2. PRISTINE: all occurrences of the reset notification"
echo "=============================================================="
grep -rn "picoquic_congestion_notification_reset" "$W" 2>/dev/null | sed "s|$W/||"

echo
echo "=============================================================="
echo "3. PRISTINE: is it EVER passed to alg_notify?"
echo "=============================================================="
# join each alg_notify( with the following 3 lines, then look for the enum
awk '/alg_notify\(/{buf=$0; n=3; next} n>0{buf=buf" "$0; n--; if(n==0) print FILENAME": "buf}' \
    $(find "$W" -name '*.c') 2>/dev/null \
  | grep -o "picoquic_congestion_notification_[a-z_]*" | sort | uniq -c | sort -rn

echo
echo "  --> if 'reset' is ABSENT from that list, the hook is dead upstream."

echo
echo "=============================================================="
echo "4. PRISTINE: what runs when a path challenge is verified"
echo "=============================================================="
awk '/picoquic_decode_path_response_frame/{f=1} f{print NR": "$0} f&&/^}/{exit}' \
    "$W/picoquic/frames.c" 2>/dev/null | grep -E "challenge_verified|update_path_rtt|reset_path_mtu|alg_notify|cwin"

echo
echo "=============================================================="
echo "5. PRISTINE: every assignment to cwin"
echo "=============================================================="
grep -rnE "(->|\.)cwin[[:space:]]*=[^=]" "$W/picoquic" 2>/dev/null | sed "s|$W/||" | head -30

echo
echo "=============================================================="
echo "6. PRISTINE: does picoquic_notify_destination_unreachable touch CC?"
echo "=============================================================="
awk '/void picoquic_notify_destination_unreachable/{f=1} f{print} f&&/^}/{exit}' \
    "$W/picoquic/quicctx.c" 2>/dev/null | head -25

echo
echo "DONE"
