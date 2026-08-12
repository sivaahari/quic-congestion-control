#!/usr/bin/env bash
# quiche_harness_build.sh -- build the bespoke qcserver/qcclient harness.
set -uo pipefail

export RUSTUP_HOME=/root/.rustup
export CARGO_HOME=/root/.cargo
export PATH="/root/.cargo/bin:$PATH"

log() { printf '[quiche_harness_build] %s\n' "$*" >&2; }

mkdir -p /home/sivaa/pvseed/results/raw/quiche
LOGFILE=/home/sivaa/pvseed/results/raw/quiche/harness_build.log
exec > >(tee "$LOGFILE") 2>&1

cd /home/sivaa/pvseed/harness/quiche || { log "FATAL: harness dir missing"; exit 1; }

log "cargo build --release"
cargo build --release 2>&1
RC=$?
log "cargo build exit code: $RC"

ls -la target/release/ 2>&1 | grep -E 'qcserver|qcclient'

exit $RC
