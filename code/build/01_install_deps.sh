#!/usr/bin/env bash
# 01_install_deps.sh -- install picoquic/picotls build dependencies
set -uo pipefail

LOG=/home/sivaa/pvseed/_build/01_install_deps.log
exec > >(tee "$LOG") 2>&1

echo "=== apt-get update ==="
apt-get update -y

echo "=== apt-get install build deps ==="
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential \
    cmake \
    pkg-config \
    libssl-dev \
    git \
    curl \
    wget \
    python3 \
    tcpdump \
    iproute2 \
    jq

echo "=== versions ==="
echo "gcc:      $(gcc --version | head -1)"
echo "cmake:    $(cmake --version | head -1)"
echo "git:      $(git --version)"
echo "openssl:  $(openssl version)"
echo "pkg-config: $(pkg-config --version)"
pkg-config --modversion openssl || echo "pkg-config cannot find openssl.pc"

echo "=== DONE 01_install_deps ==="
