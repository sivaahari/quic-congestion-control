#!/usr/bin/env bash
# quiche_install_rust.sh -- install Rust toolchain (rustup) for the quiche
# survey (PV-Seed Phase 2, subject 3). Non-interactive rustup install,
# stable toolchain, into root's home (script always runs as root per
# project convention).
set -uo pipefail

log() { printf '[install_rust] %s\n' "$*" >&2; }

export RUSTUP_HOME=/root/.rustup
export CARGO_HOME=/root/.cargo

if [ -x /root/.cargo/bin/cargo ]; then
    log "cargo already present, skipping install"
else
    log "downloading and running rustup-init (stable, non-interactive)"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup-init.sh
    RC=$?
    if [ $RC -ne 0 ]; then
        log "FATAL: failed to download rustup-init.sh (rc=$RC)"
        exit 1
    fi
    sh /tmp/rustup-init.sh -y --default-toolchain stable --profile minimal
    RC=$?
    if [ $RC -ne 0 ]; then
        log "FATAL: rustup-init failed (rc=$RC)"
        exit 1
    fi
fi

source /root/.cargo/env

log "rustc version:"
rustc --version
log "cargo version:"
cargo --version

# Persist PATH for subsequent non-interactive script invocations (each wsl.exe
# call is a fresh shell; /etc/profile.d is sourced by login shells but our
# invocations use `bash script.sh` which is non-login -- write to /etc/environment
# style file we source explicitly in later scripts instead of relying on this).
echo 'export PATH="/root/.cargo/bin:$PATH"' > /etc/profile.d/cargo.sh
chmod +x /etc/profile.d/cargo.sh

log "done"
