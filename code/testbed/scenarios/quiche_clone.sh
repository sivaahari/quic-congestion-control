#!/usr/bin/env bash
# quiche_clone.sh -- clone Cloudflare quiche (with submodules, incl. BoringSSL)
# for the PV-Seed Phase 2 survey, subject 3. Records the exact commit hash.
set -uo pipefail

log() { printf '[quiche_clone] %s\n' "$*" >&2; }

DEST=/home/sivaa/pvseed/quiche

if [ -d "$DEST/.git" ]; then
    log "quiche already cloned at $DEST, fetching latest instead of re-cloning"
    cd "$DEST" || exit 1
    git fetch --all --tags >&2
else
    log "cloning https://github.com/cloudflare/quiche.git -> $DEST"
    git clone --recursive https://github.com/cloudflare/quiche.git "$DEST" >&2
    RC=$?
    if [ $RC -ne 0 ]; then
        log "FATAL: clone failed (rc=$RC)"
        exit 1
    fi
fi

cd "$DEST" || exit 1
git config --global --add safe.directory "$DEST"

log "ensuring submodules are initialized (BoringSSL etc.)"
git submodule update --init --recursive >&2

log "HEAD commit:"
git rev-parse HEAD
log "HEAD commit (short) and subject:"
git log -1 --format='%H %ci %s'

log "submodule status:"
git submodule status

log "top-level layout:"
ls -la "$DEST"

log "apps/ layout:"
ls -la "$DEST/apps" 2>&1

log "done"
