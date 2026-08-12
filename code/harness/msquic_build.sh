#!/bin/bash
# build.sh -- compiles the PV-Seed msquic survey harness (mq_server,
# mq_client) against the msquic library built by
# _build/msquic_configure_build.sh. Not a CMake sub-project: msquic's public
# API is stable enough (src/inc/msquic.h, msquic.hpp, msquichelper.h) that a
# direct g++ invocation against the built libmsquic.so is simpler and more
# transparent than integrating a second CMake project against an uninstalled
# library, and matches the "bespoke small driver" methodology already used
# for harness/quicgo and harness/quiche in this survey.
set -uo pipefail

MSQUIC_ROOT=/home/sivaa/pvseed/msquic
MSQUIC_INC=$MSQUIC_ROOT/src/inc
MSQUIC_LIB_DIR=$MSQUIC_ROOT/build/bin/Release
HARNESS_DIR=/home/sivaa/pvseed/harness/msquic
OUT_DIR=$HARNESS_DIR/bin
mkdir -p "$OUT_DIR"

log() { printf '[harness_build] %s\n' "$*" >&2; }
die() { printf '[harness_build][FATAL] %s\n' "$*" >&2; exit 1; }

[ -f "$MSQUIC_LIB_DIR/libmsquic.so" ] || die "libmsquic.so not found at $MSQUIC_LIB_DIR -- build msquic first (_build/msquic_configure_build.sh)"

CXXFLAGS="-std=c++17 -O2 -Wall -Wextra -I$MSQUIC_INC -pthread"
LDFLAGS="-L$MSQUIC_LIB_DIR -lmsquic -pthread -Wl,-rpath,$MSQUIC_LIB_DIR"

log "building mq_server"
g++ $CXXFLAGS -o "$OUT_DIR/mq_server" "$HARNESS_DIR/server.cpp" $LDFLAGS
SERVER_RC=$?
log "mq_server build exit code: $SERVER_RC"

log "building mq_client"
g++ $CXXFLAGS -o "$OUT_DIR/mq_client" "$HARNESS_DIR/client.cpp" $LDFLAGS
CLIENT_RC=$?
log "mq_client build exit code: $CLIENT_RC"

log "built artifacts:"
ls -la "$OUT_DIR" 2>&1

if [ "$SERVER_RC" -ne 0 ] || [ "$CLIENT_RC" -ne 0 ]; then
    die "one or both builds failed (server_rc=$SERVER_RC client_rc=$CLIENT_RC)"
fi

log "quick smoke: ldd mq_server"
ldd "$OUT_DIR/mq_server" 2>&1

log "DONE"
