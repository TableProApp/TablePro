#!/usr/bin/env bash
set -euo pipefail

FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MATERIALS="$FIXTURE/materials"
SERVER_HOSTNAME="${TABLEPRO_DRIVER_TLS_HOSTNAME:-localhost}"

if [[ "${1:-}" == "--force" ]]; then
  rm -rf "$MATERIALS"
fi

if ! command -v ssh-keygen >/dev/null 2>&1; then
  echo "missing required command: ssh-keygen" >&2
  exit 1
fi

mkdir -p "$MATERIALS"
if [[ ! -f "$MATERIALS/ssh_client" ]]; then
  ssh-keygen -q -t ed25519 -N '' -C 'tablepro-driver-tls-fixture' -f "$MATERIALS/ssh_client"
fi
chmod 600 "$MATERIALS/ssh_client"
chmod 644 "$MATERIALS/ssh_client.pub"

if [[ -f "$MATERIALS/server.pem" && -f "$MATERIALS/client.crt" && -f "$MATERIALS/client.key" \
  && -f "$MATERIALS/rotated-client.crt" && -f "$MATERIALS/rotated-client.key" \
  && -f "$MATERIALS/wrong-client.crt" && -f "$MATERIALS/wrong-client.key" ]]; then
  echo "driver-tls materials already present in $MATERIALS"
  exit 0
fi

rm -rf "$MATERIALS"
mkdir -p "$MATERIALS"
ssh-keygen -q -t ed25519 -N '' -C 'tablepro-driver-tls-fixture' -f "$MATERIALS/ssh_client"
chmod 600 "$MATERIALS/ssh_client"
chmod 644 "$MATERIALS/ssh_client.pub"

if ! command -v openssl >/dev/null 2>&1; then
  echo "missing required command: openssl" >&2
  exit 1
fi

mkdir -p "$MATERIALS"
cd "$MATERIALS"

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout ca.key -out ca.crt \
  -subj "/CN=TablePro driver TLS fixture CA" \
  -addext "basicConstraints=critical,CA:TRUE" >/dev/null 2>&1

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout other-ca.key -out other-ca.crt \
  -subj "/CN=TablePro unrelated CA" \
  -addext "basicConstraints=critical,CA:TRUE" >/dev/null 2>&1

cat > server.ext <<EXT
basicConstraints=CA:FALSE
extendedKeyUsage=serverAuth
subjectAltName=DNS:${SERVER_HOSTNAME},DNS:mongo.tablepro.test,DNS:redis.tablepro.test,DNS:mysql.tablepro.test,DNS:mysql-ssh.tablepro.test,DNS:mysql-mtls.tablepro.test,DNS:mysql-mtls-ssh.tablepro.test,DNS:clickhouse.tablepro.test,DNS:mssql.tablepro.test,DNS:mssql-ssh.tablepro.test
EXT

cat > client.ext <<EXT
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
subjectAltName=DNS:bookie-driver-tls-client
EXT

openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr \
  -subj "/CN=${SERVER_HOSTNAME}" >/dev/null 2>&1
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 3650 -sha256 -extfile server.ext >/dev/null 2>&1

openssl req -newkey rsa:2048 -nodes -keyout client.key -out client.csr \
  -subj "/CN=bookie-driver-tls-client" >/dev/null 2>&1
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out client.crt -days 3650 -sha256 -extfile client.ext >/dev/null 2>&1

openssl req -newkey rsa:2048 -nodes -keyout rotated-client.key -out rotated-client.csr \
  -subj "/CN=bookie-driver-tls-client-rotated" >/dev/null 2>&1
openssl x509 -req -in rotated-client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out rotated-client.crt -days 3650 -sha256 -extfile client.ext >/dev/null 2>&1

openssl req -newkey rsa:2048 -nodes -keyout wrong-client.key -out wrong-client.csr \
  -subj "/CN=bookie-driver-tls-client-wrong" >/dev/null 2>&1
openssl x509 -req -in wrong-client.csr -CA other-ca.crt -CAkey other-ca.key -CAcreateserial \
  -out wrong-client.crt -days 3650 -sha256 -extfile client.ext >/dev/null 2>&1
rm -f server.csr client.csr rotated-client.csr wrong-client.csr server.ext client.ext ca.srl other-ca.srl

cat server.key server.crt > server.pem

chmod 600 server.key ca.key other-ca.key client.key rotated-client.key wrong-client.key
chmod 644 server.crt ca.crt other-ca.crt server.pem client.crt rotated-client.crt wrong-client.crt

echo "wrote driver-tls materials to $MATERIALS"
