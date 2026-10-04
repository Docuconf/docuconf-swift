#!/bin/sh
# Regenerates the keystore test fixtures (throwaway keys, password "changeit").
# Needs OpenSSL 3 and a JDK's keytool.
set -eu
cd "$(dirname "$0")/../Tests/DocuconfTests/Fixtures"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$tmp/k.pem" -out "$tmp/c.pem" \
  -days 36500 -subj "/CN=docuconf-test-keystore"
# Modern PKCS#12: PBES2/AES, SHA-256 MAC.
openssl pkcs12 -export -in "$tmp/c.pem" -inkey "$tmp/k.pem" -out keystore.p12 -passout pass:changeit -name test
# Legacy PKCS#12: 3DES/RC2, SHA-1 MAC (what older Java and Windows tools write).
openssl pkcs12 -export -legacy -in "$tmp/c.pem" -inkey "$tmp/k.pem" -out keystore-legacy.p12 -passout pass:changeit -name test
rm -f keystore.jks
keytool -genkeypair -keystore keystore.jks -storetype JKS -storepass changeit -keypass changeit -alias test \
  -keyalg EC -groupname secp256r1 -dname CN=docuconf-test -validity 36500
