#!/usr/bin/env bash
# quiche_build.sh -- build quiche-client / quiche-server (apps/) in release
# mode. First build compiles BoringSSL (via the `boring` crate) from source,
# so this can take several minutes.
set -uo pipefail

export RUSTUP_HOME=/root/.rustup
export CARGO_HOME=/root/.cargo
export PATH="/root/.cargo/bin:$PATH"

log() { printf '[quiche_build] %s\n' "$*" >&2; }

mkdir -p /home/sivaa/pvseed/results/raw/quiche
LOGFILE=/home/sivaa/pvseed/results/raw/quiche/build.log
exec > >(tee "$LOGFILE") 2>&1

cd /home/sivaa/pvseed/quiche || { log "FATAL: quiche dir missing"; exit 1; }

log "rustc: $(rustc --version)"
log "cargo: $(cargo --version)"
log "cmake: $(cmake --version | head -1)"
log "go: $(command -v go || echo 'NOT FOUND')"

log "building quiche_apps (release) -- this compiles BoringSSL from source, be patient"
time cargo build --package=quiche_apps --release --bins 2>&1
RC=$?
log "cargo build exit code: $RC"

log "listing target/release binaries:"
ls -la target/release/ 2>&1 | grep -E 'quiche-(client|server)'

if [ $RC -eq 0 ]; then
    log "BUILD OK"
else
    log "BUILD FAILED"
fi
exit $RC
