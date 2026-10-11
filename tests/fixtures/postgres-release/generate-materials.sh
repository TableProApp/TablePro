#!/usr/bin/env bash
set -euo pipefail

FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MATERIALS="$FIXTURE/materials"
DB_HOSTNAME="${TABLEPRO_FIXTURE_DB_HOSTNAME:-db.tablepro.test}"

if [[ "${1:-}" == "--force" ]]; then
  rm -rf "$MATERIALS" "$FIXTURE/state"
fi

if [[ -f "$MATERIALS/server.crt" && -f "$MATERIALS/client_ed25519_key" \
  && -f "$MATERIALS/client.crt" && -f "$MATERIALS/client.key" \
  && -f "$MATERIALS/rotated-client.crt" && -f "$MATERIALS/rotated-client.key" \
  && -f "$MATERIALS/wrong-client.crt" && -f "$MATERIALS/wrong-client.key" \
  && -f "$MATERIALS/ssh_relay_host_ed25519_key" ]]; then
  echo "fixture materials already present in $MATERIALS"
  exit 0
fi

rm -rf "$MATERIALS"

for command_name in openssl ssh-keygen; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "missing required command: $command_name" >&2
    exit 1
  fi
done

mkdir -p "$MATERIALS"
cd "$MATERIALS"

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout ca.key -out ca.crt \
  -subj "/CN=TablePro release fixture CA" \
  -addext "basicConstraints=critical,CA:TRUE" >/dev/null 2>&1

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout other-ca.key -out other-ca.crt \
  -subj "/CN=TablePro unrelated CA" \
  -addext "basicConstraints=critical,CA:TRUE" >/dev/null 2>&1

cat > server.ext <<EXT
basicConstraints=CA:FALSE
extendedKeyUsage=serverAuth
subjectAltName=DNS:${DB_HOSTNAME},DNS:localhost
EXT

cat > client.ext <<EXT
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
subjectAltName=DNS:bookie-mtls-client
EXT

openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr \
  -subj "/CN=${DB_HOSTNAME}" >/dev/null 2>&1
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 3650 -sha256 -extfile server.ext >/dev/null 2>&1

openssl req -newkey rsa:2048 -nodes -keyout client.key -out client.csr \
  -subj "/CN=bookie-mtls-client" >/dev/null 2>&1
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out client.crt -days 3650 -sha256 -extfile client.ext >/dev/null 2>&1

openssl req -newkey rsa:2048 -nodes -keyout rotated-client.key -out rotated-client.csr \
  -subj "/CN=bookie-mtls-client-rotated" >/dev/null 2>&1
openssl x509 -req -in rotated-client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out rotated-client.crt -days 3650 -sha256 -extfile client.ext >/dev/null 2>&1

openssl req -newkey rsa:2048 -nodes -keyout wrong-client.key -out wrong-client.csr \
  -subj "/CN=bookie-mtls-client-wrong" >/dev/null 2>&1
openssl x509 -req -in wrong-client.csr -CA other-ca.crt -CAkey other-ca.key -CAcreateserial \
  -out wrong-client.crt -days 3650 -sha256 -extfile client.ext >/dev/null 2>&1
rm -f server.csr client.csr rotated-client.csr wrong-client.csr server.ext client.ext ca.srl other-ca.srl

chmod 600 server.key ca.key other-ca.key client.key rotated-client.key wrong-client.key
chmod 644 server.crt ca.crt other-ca.crt client.crt rotated-client.crt wrong-client.crt

ssh-keygen -q -t ed25519 -N "" -C "tablepro-fixture-host" -f ssh_host_ed25519_key
ssh-keygen -q -t ed25519 -N "" -C "tablepro-fixture-relay" -f ssh_relay_host_ed25519_key
ssh-keygen -q -t ed25519 -N "" -C "tablepro-fixture-client" -f client_ed25519_key

echo "wrote fixture materials to $MATERIALS"
echo "the SSH host key changed; the release script uses a fixture-local known_hosts file"
