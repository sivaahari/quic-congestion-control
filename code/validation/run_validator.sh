#!/usr/bin/env bash
cd /home/sivaa/pvseed || exit 1
python3 _validation/revalidate_fresh.py 2>&1 | tee /tmp/val.out | grep -E "^### picoquic" -A 14
echo
tail -4 /tmp/val.out
