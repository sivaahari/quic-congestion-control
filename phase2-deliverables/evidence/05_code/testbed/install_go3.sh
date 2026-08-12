#!/bin/bash
set -uo pipefail
OUT=/home/sivaa/pvseed/testbed/scenarios/install_go3_out.txt
WORKDIR=/home/sivaa/pvseed/testbed/scenarios
FILENAME=go1.26.5.linux-amd64.tar.gz
SHA256=5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053
{
  set -e
  cd "$WORKDIR"
  echo "downloading $FILENAME"
  curl -fL -o "$FILENAME" "https://go.dev/dl/$FILENAME"
  echo "computed sha256:"
  sha256sum "$FILENAME"
  echo "expected sha256: $SHA256"
  echo "$SHA256  $FILENAME" | sha256sum -c -
  echo "sha256 verified OK"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$FILENAME"
  /usr/local/go/bin/go version
  rm -f "$FILENAME"
  echo "cleaned up tarball"
} > "$OUT" 2>&1
echo "INSTALL_DONE"
