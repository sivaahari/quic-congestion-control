#!/bin/bash
# Clean recon, no set -x, to avoid stdout/stderr interleaving.
{
echo "GO_PATH:$(command -v go || echo NONE)"
if command -v go >/dev/null 2>&1; then
  go version
  echo "GOROOT:$(go env GOROOT 2>&1)"
  echo "GOPATH:$(go env GOPATH 2>&1)"
fi
echo "---"
echo "GIT_PATH:$(command -v git || echo NONE)"
git --version
echo "---"
ls -la /usr/local/go/bin 2>&1 || echo "no /usr/local/go"
echo "---"
apt list --installed 2>/dev/null | grep -i golang || echo "no golang apt pkg"
} > /home/sivaa/pvseed/testbed/scenarios/quicgo_recon2_out.txt 2>&1
echo "WROTE_OUTPUT"
