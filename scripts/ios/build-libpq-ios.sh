#!/usr/bin/env bash
set -eo pipefail

# Build static libpq for iOS using xcodebuild/xcrun clang directly.
# No autotools configure needed — compile source files directly.
#
# Requires: OpenSSL xcframework already built
# Produces: Libs/ios/LibPQ.xcframework/

PG_VERSION="17.4"
PG_SHA256="c4605b73fea11963406699f949b966e5d173a7ee0ccaef8938dec0ca8a995fe7"
IOS_DEPLOY_TARGET="17.0"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIBS_DIR="$PROJECT_DIR/Libs/ios"
BUILD_DIR="$(mktemp -d)"

cleanup() {
    echo "   Cleaning up build directory..."
    rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

echo "Building static libpq (PostgreSQL $PG_VERSION) for iOS"
echo "   Build dir: $BUILD_DIR"

# --- Download & extract ---

echo "=> Downloading PostgreSQL $PG_VERSION..."
curl -f#SL "https://ftp.postgresql.org/pub/source/v$PG_VERSION/postgresql-$PG_VERSION.tar.bz2" \
    -o "$BUILD_DIR/postgresql.tar.bz2"
echo "$PG_SHA256  $BUILD_DIR/postgresql.tar.bz2" | shasum -a 256 -c -
tar xjpf "$BUILD_DIR/postgresql.tar.bz2" -C "$BUILD_DIR"
PG_SRC="$BUILD_DIR/postgresql-$PG_VERSION"
echo "   Done."

# --- Generate config headers manually (no configure needed for cross-compile) ---
# PostgreSQL's autoconf configure is unreliable for cross-compilation and slow.
# We generate the required headers directly with known-good values for iOS/arm64.

echo "=> Generating config headers..."
NATIVE_DIR="$BUILD_DIR/pg-native"
cp -R "$PG_SRC" "$NATIVE_DIR"
cd "$NATIVE_DIR"

mkdir -p "$NATIVE_DIR/src/include"

cat > "$NATIVE_DIR/src/include/pg_config.h" << 'PGCFG'
#define PG_MAJORVERSION "17"
#define PG_MAJORVERSION_NUM 17
#define PG_MINORVERSION_NUM 4
#define PG_VERSION "17.4"
#define PG_VERSION_NUM 170004
#define BLCKSZ 8192
#define XLOG_BLCKSZ 8192
#define RELSEG_SIZE 131072
#define DEF_PGPORT 5432
#define DEF_PGPORT_STR "5432"
#define MAXIMUM_ALIGNOF 8
#define SIZEOF_VOID_P 8
#define SIZEOF_SIZE_T 8
#define SIZEOF_LONG 8
#define SIZEOF_OFF_T 8
#define FLOAT8PASSBYVAL 1
#define HAVE_LONG_INT_64 1
#define INT64_IS_BUSTED 0
#define PG_INT64_TYPE long int
#define HAVE_STDBOOL_H 1
#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STRINGS_H 1
#define HAVE_STRING_H 1
#define HAVE_UNISTD_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_MEMORY_H 1
#define HAVE_NETINET_IN_H 1
#define HAVE_NETDB_H 1
#define HAVE_SYS_SOCKET_H 1
#define HAVE_SYS_UN_H 1
#define HAVE_SYS_SELECT_H 1
#define HAVE_POLL_H 1
#define HAVE_SYS_POLL_H 1
#define HAVE_TERMIOS_H 1
#define HAVE_DLFCN_H 1
#define HAVE_GETADDRINFO 1
#define HAVE_GETHOSTBYNAME_R 0
#define HAVE_INET_ATON 1
#define HAVE_STRERROR_R 1
#define HAVE_STRLCAT 1
#define HAVE_STRLCPY 1
#define HAVE_STRNLEN 1
#define HAVE_STRSIGNAL 1
#define HAVE_PREAD 1
#define HAVE_PWRITE 1
#define HAVE_MKDTEMP 1
#define HAVE_RANDOM 1
#define HAVE_SRANDOM 1
#define HAVE_DLOPEN 1
#define HAVE_FDATASYNC 0
#define HAVE_WCTYPE_H 1
#define HAVE_LANGINFO_H 1
#define HAVE_LOCALE_T 1
#define ENABLE_THREAD_SAFETY 1
#define USE_OPENSSL 1
#define HAVE_OPENSSL_INIT_SSL 1
#define HAVE_BIO_METH_NEW 1
#define HAVE_HMAC_CTX_NEW 1
#define HAVE_HMAC_CTX_FREE 1
#define HAVE_SSL_CTX_SET_CERT_CB 1
#define HAVE_X509_GET_SIGNATURE_NID 1
#define HAVE_STRUCT_SOCKADDR_STORAGE 1
#define HAVE_STRUCT_SOCKADDR_STORAGE_SS_LEN 1
#define HAVE_STRUCT_SOCKADDR_STORAGE_SS_FAMILY 1
#define ACCEPT_TYPE_ARG1 int
#define ACCEPT_TYPE_ARG2 struct sockaddr *
#define ACCEPT_TYPE_ARG3 socklen_t
#define ACCEPT_TYPE_RETURN int
#define MEMSET_LOOP_LIMIT 1024
#define PG_KRB_SRVNAM "postgres"
#define PG_PRINTF_ATTRIBUTE printf
#define STRERROR_R_INT 1
#define HAVE_DECL_STRLCAT 1
#define HAVE_DECL_STRLCPY 1
#define HAVE_DECL_STRTOINT 0
#define HAVE_STRONG_RANDOM 1
#define pg_restrict __restrict
#define HAVE_FUNCNAME__FUNC 1
#define INT64_MODIFIER "l"
#define HAVE_INT64_TIMESTAMP 1
PGCFG

cat > "$NATIVE_DIR/src/include/pg_config_ext.h" << 'PGCFGEXT'
#define PG_INT64_TYPE long int
PGCFGEXT

cat > "$NATIVE_DIR/src/include/pg_config_os.h" << 'PGCFGOS'
/* Darwin (macOS/iOS) */
#define HAVE_DECL_STRLCAT 1
#define HAVE_DECL_STRLCPY 1
PGCFGOS

cat > "$NATIVE_DIR/src/include/pg_config_paths.h" << 'PGPATHS'
#define PGBINDIR "/usr/local/pgsql/bin"
#define PGSHAREDIR "/usr/local/pgsql/share"
#define SYSCONFDIR "/usr/local/pgsql/etc"
#define INCLUDEDIR "/usr/local/pgsql/include"
#define PKGINCLUDEDIR "/usr/local/pgsql/include"
#define INCLUDEDIRSERVER "/usr/local/pgsql/include/server"
#define LIBDIR "/usr/local/pgsql/lib"
#define PKGLIBDIR "/usr/local/pgsql/lib"
#define LOCALEDIR "/usr/local/pgsql/share/locale"
#define DOCDIR "/usr/local/pgsql/share/doc"
#define HTMLDIR "/usr/local/pgsql/share/doc"
#define MANDIR "/usr/local/pgsql/share/man"
PGPATHS

echo "   Done."

# --- Locate OpenSSL ---

setup_openssl() {
    local PLATFORM_KEY=$1
    local PREFIX="$BUILD_DIR/openssl-$PLATFORM_KEY"

    local SSL_LIB
    SSL_LIB=$(find "$LIBS_DIR/OpenSSL-SSL.xcframework" -path "*$PLATFORM_KEY*/libssl.a" | head -1)
    local CRYPTO_LIB
    CRYPTO_LIB=$(find "$LIBS_DIR/OpenSSL-Crypto.xcframework" -path "*$PLATFORM_KEY*/libcrypto.a" | head -1)
    local HEADERS
    HEADERS=$(find "$LIBS_DIR/OpenSSL-SSL.xcframework" -path "*$PLATFORM_KEY*/Headers" -type d | head -1)

    if [ -z "$SSL_LIB" ] || [ -z "$CRYPTO_LIB" ]; then
        echo "ERROR: OpenSSL not found for $PLATFORM_KEY"
        exit 1
    fi

    mkdir -p "$PREFIX/lib" "$PREFIX/include"
    cp "$SSL_LIB" "$PREFIX/lib/"
    cp "$CRYPTO_LIB" "$PREFIX/lib/"
    [ -d "$HEADERS" ] && cp -R "$HEADERS/openssl" "$PREFIX/include/" 2>/dev/null || true

    OPENSSL_PREFIX="$PREFIX"
}

# --- Compile libpq for one iOS slice ---

build_slice() {
    local SDK_NAME=$1       # iphoneos or iphonesimulator
    local ARCH=$2
    local PLATFORM_KEY=$3
    local INSTALL_DIR="$BUILD_DIR/install-$SDK_NAME-$ARCH"

    echo "=> Compiling libpq for $SDK_NAME ($ARCH)..."

    setup_openssl "$PLATFORM_KEY"

    local SDK
    SDK=$(xcrun --sdk "$SDK_NAME" --show-sdk-path)
    local CC
    CC=$(xcrun --sdk "$SDK_NAME" -f cc)
    local AR
    AR=$(xcrun --sdk "$SDK_NAME" -f ar)
    local RANLIB
    RANLIB=$(xcrun --sdk "$SDK_NAME" -f ranlib)

    local TARGET_FLAG
    if [ "$SDK_NAME" = "iphonesimulator" ]; then
        TARGET_FLAG="-target arm64-apple-ios${IOS_DEPLOY_TARGET}-simulator"
    else
        TARGET_FLAG="-target arm64-apple-ios${IOS_DEPLOY_TARGET}"
    fi

    local -a CFLAGS=(-arch "$ARCH" -isysroot "$SDK" "$TARGET_FLAG" -mios-version-min="$IOS_DEPLOY_TARGET" -O2 -DHAVE_STRCHRNUL=1 -Wno-int-conversion -Wno-ignored-attributes -Wno-implicit-function-declaration -Wno-error -w)
    local -a PG_INCLUDES=(-I"$NATIVE_DIR/src/include" -I"$NATIVE_DIR/src/include/port/darwin" -I"$NATIVE_DIR/src/interfaces/libpq" -I"$NATIVE_DIR/src/port" -I"$OPENSSL_PREFIX/include" -I"$NATIVE_DIR/src/common")

    local OBJ_DIR="$BUILD_DIR/obj-$SDK_NAME-$ARCH"
    mkdir -p "$OBJ_DIR" "$INSTALL_DIR/lib" "$INSTALL_DIR/include"

    # --- libpq source files ---
    local LIBPQ_SRCS=(
        src/interfaces/libpq/fe-auth.c
        src/interfaces/libpq/fe-auth-scram.c
        src/interfaces/libpq/fe-connect.c
        src/interfaces/libpq/fe-exec.c
        src/interfaces/libpq/fe-lobj.c
        src/interfaces/libpq/fe-misc.c
        src/interfaces/libpq/fe-print.c
        src/interfaces/libpq/fe-protocol3.c
        src/interfaces/libpq/fe-secure.c
        src/interfaces/libpq/fe-secure-openssl.c
        src/interfaces/libpq/fe-trace.c
        src/interfaces/libpq/legacy-pqsignal.c
        src/interfaces/libpq/libpq-events.c
        src/interfaces/libpq/pqexpbuffer.c
        src/interfaces/libpq/fe-secure-common.c
        src/interfaces/libpq/fe-cancel.c
    )

    # --- Common library source files needed by libpq ---
    local COMMON_SRCS=(
        src/common/base64.c
        src/common/cryptohash.c
        src/common/cryptohash_openssl.c
        src/common/hmac.c
        src/common/hmac_openssl.c
        src/common/ip.c
        src/common/link-canary.c
        src/common/md5_common.c
        src/common/scram-common.c
        src/common/saslprep.c
        src/common/string.c
        src/common/stringinfo.c
        src/common/unicode_norm.c
        src/common/wchar.c
        src/common/encnames.c
        src/common/fe_memutils.c
        src/common/psprintf.c
        src/common/logging.c
        src/common/percentrepl.c
        src/common/sha1.c
        src/common/sha1_int.c
        src/common/sha2.c
        src/common/sha2_int.c
        src/common/pg_prng.c
        src/common/md5.c
        src/common/md5_int.c
    )

    # --- Port library source files ---
    local PORT_SRCS=(
        src/port/chklocale.c
        src/port/inet_net_ntop.c
        src/port/noblock.c
        src/port/pg_strong_random.c
        src/port/pgstrsignal.c
        src/port/snprintf.c
        src/port/strerror.c
        src/port/thread.c
        src/port/path.c
        src/port/pgstrcasecmp.c
        src/port/explicit_bzero.c
        src/port/user.c
        src/port/pg_bitutils.c
    )

    cd "$NATIVE_DIR"

    # Compile all source files
    local ALL_OBJS=()
    local FAILED_SRCS=()
    local MISSING_SRCS=()
    for src in "${LIBPQ_SRCS[@]}" "${COMMON_SRCS[@]}" "${PORT_SRCS[@]}"; do
        local obj_name
        obj_name=$(basename "${src%.c}.o")
        # A source that is not there used to be skipped in silence, so a PostgreSQL bump that
        # renamed or moved a file produced a libpq.a quietly missing that object. Only a
        # compile failure was ever reported.
        if [ ! -f "$src" ]; then
            MISSING_SRCS+=("$src")
            continue
        fi
        if "$CC" "${CFLAGS[@]}" "${PG_INCLUDES[@]}" -DFRONTEND -c "$src" -o "$OBJ_DIR/$obj_name" 2>"$OBJ_DIR/${obj_name}.err"; then
            ALL_OBJS+=("$OBJ_DIR/$obj_name")
        else
            FAILED_SRCS+=("$src")
            echo "   FAILED: $src"
            cat "$OBJ_DIR/${obj_name}.err"
        fi
    done

    if [ ${#MISSING_SRCS[@]} -gt 0 ]; then
        echo ""
        echo "ERROR: ${#MISSING_SRCS[@]} source file(s) listed here are not in PostgreSQL $PG_VERSION:"
        printf '   %s\n' "${MISSING_SRCS[@]}"
        echo ""
        echo "Update the source lists in this script to match the version being built."
        exit 1
    fi

    if [ ${#FAILED_SRCS[@]} -gt 0 ]; then
        echo ""
        echo "ERROR: ${#FAILED_SRCS[@]} source files failed to compile:"
        printf '   %s\n' "${FAILED_SRCS[@]}"
        echo ""
        echo "Fix the compilation errors above before creating xcframework."
        exit 1
    fi

    # strchrnul compat
    cat > "$OBJ_DIR/strchrnul_compat.c" << 'EOF'
#include <stddef.h>
char *strchrnul(const char *s, int c) {
    while (*s && *s != (char)c) s++;
    return (char *)s;
}
EOF
    "$CC" "${CFLAGS[@]}" -c "$OBJ_DIR/strchrnul_compat.c" -o "$OBJ_DIR/strchrnul_compat.o"
    ALL_OBJS+=("$OBJ_DIR/strchrnul_compat.o")

    # Create static library
    $AR rcs "$INSTALL_DIR/lib/libpq.a" "${ALL_OBJS[@]}"
    $RANLIB "$INSTALL_DIR/lib/libpq.a"

    local OBJ_COUNT=${#ALL_OBJS[@]}
    echo "   Compiled $OBJ_COUNT objects → libpq.a"

    # Copy headers
    cp "$NATIVE_DIR/src/interfaces/libpq/libpq-fe.h" "$INSTALL_DIR/include/"
    cp "$NATIVE_DIR/src/include/postgres_ext.h" "$INSTALL_DIR/include/"
    cp "$NATIVE_DIR/src/include/pg_config_ext.h" "$INSTALL_DIR/include/" 2>/dev/null || true

    echo "   Installed to $INSTALL_DIR"
}

# --- Build both slices ---

build_slice "iphoneos" "arm64" "ios-arm64"
build_slice "iphonesimulator" "arm64" "ios-arm64-simulator"

# --- Create xcframework ---

DEVICE_DIR="$BUILD_DIR/install-iphoneos-arm64"
SIM_DIR="$BUILD_DIR/install-iphonesimulator-arm64"

rm -rf "$LIBS_DIR/LibPQ.xcframework"

echo "=> Creating LibPQ.xcframework..."

xcodebuild -create-xcframework \
    -library "$DEVICE_DIR/lib/libpq.a" \
    -headers "$DEVICE_DIR/include" \
    -library "$SIM_DIR/lib/libpq.a" \
    -headers "$SIM_DIR/include" \
    -output "$LIBS_DIR/LibPQ.xcframework"

echo ""
echo "libpq (PostgreSQL $PG_VERSION) for iOS built successfully!"
echo "   $LIBS_DIR/LibPQ.xcframework"

# Verify
echo ""
echo "=> Verifying device slice..."
lipo -info "$DEVICE_DIR/lib/libpq.a"
otool -l "$DEVICE_DIR/lib/libpq.a" | grep -A4 "LC_BUILD_VERSION" | head -5

echo ""
echo "Done!"
