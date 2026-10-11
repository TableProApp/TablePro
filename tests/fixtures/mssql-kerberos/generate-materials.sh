#!/usr/bin/env bash
set -euo pipefail

FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MATERIALS="$FIXTURE/materials"

rm -rf "$MATERIALS"
mkdir -p "$MATERIALS"
cd "$MATERIALS"

openssl req -x509 -newkey rsa:2048 -sha256 -days 30 -nodes \
  -keyout ca.key -out ca.crt \
  -subj "/CN=BookiE SQL Server Kerberos test CA" \
  -addext "basicConstraints=critical,CA:TRUE" >/dev/null 2>&1

openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr \
  -subj "/CN=mssql.domain1.sink.test" >/dev/null 2>&1
cat > server.ext <<'EOF'
basicConstraints=CA:FALSE
extendedKeyUsage=serverAuth
subjectAltName=DNS:mssql.domain1.sink.test
EOF
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 30 -sha256 -extfile server.ext >/dev/null 2>&1

rm -f ca.key ca.srl server.csr server.ext
chmod 0444 ca.crt server.crt
# The key is an ephemeral local fixture artifact mounted read-only into the
# vendor image, whose numeric mssql uid/gid differs from the host account.
chmod 0444 server.key
