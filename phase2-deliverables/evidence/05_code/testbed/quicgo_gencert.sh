#!/bin/bash
set -uo pipefail
OUT=/home/sivaa/pvseed/testbed/scenarios/quicgo_gencert_out.txt
CERTDIR=/home/sivaa/pvseed/harness/quicgo/certs
{
  set -e
  mkdir -p "$CERTDIR"
  openssl req -x509 -newkey rsa:2048 -keyout "$CERTDIR/key.pem" -out "$CERTDIR/cert.pem" \
    -days 3650 -nodes -subj "/CN=pvseed.test" \
    -addext "subjectAltName=DNS:pvseed.test,IP:10.0.9.1"
  chmod 644 "$CERTDIR/cert.pem" "$CERTDIR/key.pem"
  echo "--- generated cert ---"
  openssl x509 -in "$CERTDIR/cert.pem" -noout -subject -dates -ext subjectAltName
  ls -la "$CERTDIR"
} > "$OUT" 2>&1
echo "GENCERT_DONE"
