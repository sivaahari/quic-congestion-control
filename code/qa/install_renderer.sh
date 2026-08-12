#!/usr/bin/env bash
# Install a headless renderer so the deck can be visually inspected.
# fonts-crosextra-carlito is metric-compatible with Calibri (python-pptx's
# default font), so text-fit in the render matches what PowerPoint will do.
#
# NOTE: lives in the project tree, not /tmp -- this WSL2 VM wipes /tmp when it
# idles between invocations, which silently deleted an earlier copy of this
# script before it could run.
set -x
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    libreoffice-impress poppler-utils \
    fonts-liberation fonts-crosextra-carlito
echo "=== versions ==="
soffice --version || echo "soffice STILL MISSING"
pdftoppm -v 2>&1 | head -1 || echo "pdftoppm STILL MISSING"
