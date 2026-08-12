#!/usr/bin/env bash
# 08_smoke_migration_v2.sh -- loopback smoke test WITH realistic shaping
# (50mbit/20ms, mirroring path A) so the connection lives long enough for
# CID-stash / path-allowed subscriptions to resolve before the transfer
# finishes. Tries two variants: (1) -A + -f2, no multipath; (2) -A + -M
# (multipath enabled) to see whether multipath negotiation is required
# for the demo's -A probe to actually fire.
set -uo pipefail

WORK=/home/sivaa/pvseed/_build/smoke2
rm -rf "$WORK"
mkdir -p "$WORK/webroot"

cd /home/sivaa/pvseed/picoquic/build

echo "=== generating 32MB test file ==="
dd if=/dev/zero of="$WORK/webroot/bigfile.bin" bs=1M count=32 status=none

echo "=== shaping lo: 50mbit / 20ms delay (mirrors path A) ==="
tc qdisc del dev lo root >/dev/null 2>&1 || true
tc qdisc add dev lo root handle 1: tbf rate 50mbit burst 3200 limit 1600000
tc qdisc add dev lo parent 1: handle 10: netem delay 20ms
tc qdisc show dev lo

run_variant() {
    local label=$1; shift
    local extra_client_args=("$@")
    local vdir="$WORK/$label"
    mkdir -p "$vdir/qlog_server" "$vdir/qlog_client" "$vdir/downloads"

    echo ""
    echo "############ VARIANT: $label ############"
    echo "client args: ${extra_client_args[*]}"

    ./picoquicdemo -p 4433 -c ../certs/cert.pem -k ../certs/key.pem -w "$WORK/webroot" \
        -q "$vdir/qlog_server" -l "$vdir/server.log" "${label_server_extra[@]}" > "$vdir/server_stdout.log" 2>&1 &
    local SERVER_PID=$!
    sleep 1

    timeout 40 ./picoquicdemo -G newreno -q "$vdir/qlog_client" \
        -o "$vdir/downloads" -l "$vdir/client.log" -n localhost -a hq-interop \
        "${extra_client_args[@]}" \
        127.0.0.1 4433 "bigfile.bin" > "$vdir/client_stdout.log" 2>&1
    echo "client exit code: $?"

    sleep 1
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true

    echo "--- client stdout tail (migration-relevant) ---"
    grep -iE 'migrat|address|cnxid|error|path|Received [0-9]+ bytes' "$vdir/client_stdout.log"
    echo "--- qlog files ---"
    find "$vdir/qlog_client" "$vdir/qlog_server" -type f
}

label_server_extra=()
run_variant variant1_A_f2 -A "127.0.0.2/0" -f 2

label_server_extra=(-M)
run_variant variant2_A_M -A "127.0.0.2/0" -M

echo ""
echo "=== ALL VARIANTS DONE ==="

echo "=== cleanup: remove lo shaping ==="
tc qdisc del dev lo root >/dev/null 2>&1 || true
