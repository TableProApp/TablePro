#!/usr/bin/env bash
#
# Whether the PEM that SystemTrustAnchors builds from this Mac's trust settings lets the bundled OpenSSL verify a live
# server the way libpq's verify-full does: SSL_VERIFY_PEER plus SSL_set1_host. The bundled OpenSSL's own default store
# is checked too. Its OPENSSLDIR is the libs builder's temporary folder, so that check is expected to fail with
# "unable to get local issuer certificate".
#
# Builds the shipping SystemTrustAnchors.swift with a small main that writes the PEM, and a TLS client linked against
# apple/Libs/libssl.a and libcrypto.a (run apple/scripts/download-libs.sh first, or set LIBS_DIR). Needs the network.
# A host is any TLS server whose chain should verify against this Mac's roots; port 443 unless one is given.
#
# Usage: apple/scripts/probes/check-system-trust-anchors.sh [host[:port]]...   (default: www.postgresql.org)
# Exit 0: every host verifies with the exported roots. Exit 1: one does not, or the probe could not run.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIBS="${LIBS_DIR:-$ROOT/Libs}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for lib in libssl.a libcrypto.a; do
    if [[ ! -f "$LIBS/$lib" ]]; then
        echo "Missing $LIBS/$lib. Run apple/scripts/download-libs.sh first." >&2
        exit 1
    fi
done

cat > "$WORK/main.swift" << 'EOF'
import Foundation

let source = SecuritySystemTrustSource()
let start = Date()
let pem = try SystemTrustAnchors.pem(from: source)
let elapsed = Int(Date().timeIntervalSince(start) * 1_000)
try pem.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
let roots = try SystemTrustAnchors.trustedRoots(from: source).count
print("exported \(roots) roots, \(pem.count) bytes, \(elapsed) ms")
EOF

cat > "$WORK/check.c" << 'EOF'
#include <netdb.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

const void *TLS_client_method(void);
void *SSL_CTX_new(const void *method);
void SSL_CTX_free(void *ctx);
int SSL_CTX_set_default_verify_paths(void *ctx);
int SSL_CTX_load_verify_locations(void *ctx, const char *file, const char *dir);
void SSL_CTX_set_verify(void *ctx, int mode, void *callback);
void *SSL_new(void *ctx);
void SSL_free(void *ssl);
int SSL_set_fd(void *ssl, int fd);
long SSL_ctrl(void *ssl, int cmd, long larg, void *parg);
int SSL_set1_host(void *ssl, const char *host);
int SSL_connect(void *ssl);
long SSL_get_verify_result(const void *ssl);
const char *X509_verify_cert_error_string(long n);

// SSL_set_tlsext_host_name is a macro over SSL_ctrl; 55 is SSL_CTRL_SET_TLSEXT_HOSTNAME.
static int check(const char *label, const char *pem, const char *host, const char *port) {
    void *ctx = SSL_CTX_new(TLS_client_method());
    if (pem) {
        if (SSL_CTX_load_verify_locations(ctx, pem, NULL) != 1) {
            printf("  %-17s could not load %s\n", label, pem);
            return 0;
        }
    } else {
        SSL_CTX_set_default_verify_paths(ctx);
    }
    SSL_CTX_set_verify(ctx, 1, NULL);

    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, port, &hints, &res) != 0) {
        printf("  %-17s cannot resolve %s\n", label, host);
        return 0;
    }
    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (connect(fd, res->ai_addr, res->ai_addrlen) != 0) {
        printf("  %-17s cannot connect to %s:%s\n", label, host, port);
        freeaddrinfo(res);
        return 0;
    }
    freeaddrinfo(res);
    void *ssl = SSL_new(ctx);
    SSL_set_fd(ssl, fd);
    SSL_ctrl(ssl, 55, 0, (void *)host);
    SSL_set1_host(ssl, host);
    int handshake = SSL_connect(ssl);
    long verify = SSL_get_verify_result(ssl);
    printf("  %-17s handshake %s, verify %ld (%s)\n", label, handshake == 1 ? "ok" : "failed", verify,
           X509_verify_cert_error_string(verify));
    SSL_free(ssl);
    close(fd);
    SSL_CTX_free(ctx);
    return handshake == 1 && verify == 0;
}

int main(int argc, char **argv) {
    if (argc < 4) return 2;
    check("default store", NULL, argv[2], argv[3]);
    return check("exported roots", argv[1], argv[2], argv[3]) ? 0 : 1;
}
EOF

arch="$(uname -m)"
xcrun swiftc -swift-version 6 -target "$arch-apple-macos13.0" -o "$WORK/export-roots" \
    "$ROOT/Packages/TableProCore/Sources/TableProTLSClientIdentity/SystemTrustAnchors.swift" "$WORK/main.swift"
clang -arch "$arch" -mmacosx-version-min=13.0 -o "$WORK/check" "$WORK/check.c" \
    "$LIBS/libssl.a" "$LIBS/libcrypto.a" -lz

"$WORK/export-roots" "$WORK/roots.pem"

status=0
for target in "${@:-www.postgresql.org}"; do
    host="${target%%:*}"
    port="443"
    [[ "$target" == *:* ]] && port="${target##*:}"
    echo "== $host:$port"
    "$WORK/check" "$WORK/roots.pem" "$host" "$port" || status=1
done
exit "$status"
