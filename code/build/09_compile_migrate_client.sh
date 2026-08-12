#!/usr/bin/env bash
# 09_compile_migrate_client.sh -- compile the custom migrate_client
# (copy of picoquicdemo.c with a PV-Seed-free timing/IP tweak to the
# existing -f 3 migration path) against the already-built picoquic/picotls
# static libraries.
set -uo pipefail

PQ=/home/sivaa/pvseed/picoquic
PT=/home/sivaa/pvseed/picotls
HARNESS=/home/sivaa/pvseed/harness
LOG=/home/sivaa/pvseed/_build/09_compile_migrate_client.log

exec > >(tee "$LOG") 2>&1

echo "=== compiling migrate_client.c ==="
gcc -O2 -g -Wall \
    -I "$PQ/picoquic" -I "$PQ/picohttp" -I "$PT/include" \
    -c "$HARNESS/migrate_client.c" -o "$HARNESS/migrate_client.o"
echo "compile migrate_client.c: rc=$?"

echo "=== compiling getopt.c companion ==="
gcc -O2 -g -Wall \
    -I "$PQ/picoquic" -I "$PQ/picohttp" -I "$PT/include" \
    -c "$PQ/picoquicfirst/getopt.c" -o "$HARNESS/migrate_getopt.o"
echo "compile getopt.c: rc=$?"

echo "=== linking migrate_client ==="
gcc -O2 -g \
    "$HARNESS/migrate_client.o" "$HARNESS/migrate_getopt.o" \
    "$PQ/build/libwt_baton.a" \
    "$PQ/build/libpicoquic-log.a" \
    "$PQ/build/libpicohttp-core.a" \
    "$PQ/build/libpicoquic-core.a" \
    "$PT/libpicotls-openssl.a" \
    "$PT/libpicotls-fusion.a" \
    "$PT/libpicotls-minicrypto.a" \
    "$PT/libpicotls-core.a" \
    -lssl -lcrypto -lpthread -lm \
    -o "$HARNESS/migrate_client"
LINK_RC=$?
echo "link: rc=$LINK_RC"

ls -la "$HARNESS/migrate_client" 2>&1

echo "=== DONE (link_rc=$LINK_RC) ==="
