#!/bin/sh
# Writes a self-signed ECDSA certificate for gateway.internal, valid for 90 days, to
# dev-root/etc/gateway/tls (git-ignored), so the gateway example boots locally:
#
#   Examples/Gateway/make-dev-tls.sh
#   DOCUCONF_FILE_ROOT=Examples/Gateway/dev-root DATABASE_URL=postgres://localhost/gw swift run --traits TLS GatewayExample
set -eu
dir="$(dirname "$0")/dev-root/etc/gateway/tls"
mkdir -p "$dir"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 90 \
    -subj "/CN=gateway.internal" -addext "subjectAltName=DNS:gateway.internal" \
    -keyout "$dir/tls.key" -out "$dir/tls.crt" 2>/dev/null
echo "wrote $dir/tls.crt and $dir/tls.key"
