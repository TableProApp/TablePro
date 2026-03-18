#!/usr/bin/env bash
set -euo pipefail

ARCH="${1:-}"

if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then
  echo "Usage: $0 <arm64|x86_64>"
  exit 1
fi

# Prepare libmariadb
echo "📦 Preparing libmariadb.a for $ARCH..."
cp "Libs/libmariadb_${ARCH}.a" "Libs/libmariadb.a"
echo "✅ libmariadb.a ready"
lipo -info Libs/libmariadb.a
ls -lh Libs/libmariadb.a

# Prepare libpq + OpenSSL
echo "📦 Preparing libpq + OpenSSL static libraries for $ARCH..."
for lib in libpq libpgcommon libpgport libssl libcrypto; do
  cp "Libs/${lib}_${ARCH}.a" "Libs/${lib}.a"
done
echo "✅ libpq + OpenSSL libraries ready"
ls -lh Libs/lib{pq,pgcommon,pgport,ssl,crypto}.a

# Prepare hiredis
echo "📦 Preparing hiredis static libraries for $ARCH..."
for lib in libhiredis libhiredis_ssl; do
  cp "Libs/${lib}_${ARCH}.a" "Libs/${lib}.a"
done
echo "✅ hiredis libraries ready"
ls -lh Libs/lib{hiredis,hiredis_ssl}.a
