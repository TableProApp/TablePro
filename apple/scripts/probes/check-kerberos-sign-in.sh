#!/usr/bin/env bash
# Signs in to PostgreSQL and MariaDB with Kerberos through the libpq and Connector/C in Libs/,
# against a throwaway MIT KDC in Docker, the way the drivers do: a ticket requested from a
# principal and password into a private FILE cache, then KRB5CCNAME pointed at it.
#
# Run after build-libpq.sh or build-mariadb.sh, before publishing the libs. It fails when either
# library lost its GSSAPI support or no longer signs in with the GSS framework.
#
# Usage: scripts/probes/check-kerberos-sign-in.sh   (LIBS_DIR overrides apple/Libs)
# Needs Docker. Ports 28888, 25433 and 23307 on 127.0.0.1, or KDC_PORT, PG_PORT and MARIADB_PORT.

set -euo pipefail

PROBE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLE_DIR="$(cd "$PROBE_DIR/../.." && pwd)"
LIBS_DIR="${LIBS_DIR:-$APPLE_DIR/Libs}"
KDC_PORT="${KDC_PORT:-28888}"
PG_PORT="${PG_PORT:-25433}"
MARIADB_PORT="${MARIADB_PORT:-23307}"
ARCH="$(uname -m)"
IMAGE=tablepro-kerberos-probe
CONTAINER="tablepro-kerberos-probe-$$"
WORK_DIR="$(mktemp -d)"
trap 'docker rm -f "$CONTAINER" > /dev/null 2>&1 || true; rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/image"
cat > "$WORK_DIR/image/Dockerfile" << 'EOF'
FROM debian:bookworm-slim
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    krb5-kdc krb5-admin-server postgresql mariadb-server mariadb-plugin-gssapi-server \
    && rm -rf /var/lib/apt/lists/*
COPY start.sh /start.sh
CMD ["bash", "/start.sh"]
EOF
cat > "$WORK_DIR/image/start.sh" << 'EOF'
set -e
printf '[libdefaults]\n default_realm = TEST.TABLEPRO\n[realms]\n TEST.TABLEPRO = {\n  kdc = 127.0.0.1:88\n }\n' > /etc/krb5.conf
mkdir -p /etc/krb5kdc
printf '[kdcdefaults]\n kdc_ports = 88\n kdc_tcp_ports = 88\n[realms]\n TEST.TABLEPRO = {\n  database_name = /var/lib/krb5kdc/principal\n  key_stash_file = /etc/krb5kdc/stash\n }\n' > /etc/krb5kdc/kdc.conf
kdb5_util create -s -r TEST.TABLEPRO -P masterpass > /dev/null
kadmin.local -q "addprinc -pw alicepass alice" > /dev/null
kadmin.local -q "addprinc -randkey postgres/localhost" > /dev/null
kadmin.local -q "addprinc -randkey mariadb/localhost" > /dev/null
kadmin.local -q "ktadd -k /etc/postgres.keytab postgres/localhost" > /dev/null
kadmin.local -q "ktadd -k /etc/mariadb.keytab mariadb/localhost" > /dev/null
chown postgres /etc/postgres.keytab
chown mysql /etc/mariadb.keytab
krb5kdc
PGC="/etc/postgresql/$(ls /etc/postgresql)/main"
echo "listen_addresses = '*'" >> "$PGC/postgresql.conf"
echo "krb_server_keyfile = '/etc/postgres.keytab'" >> "$PGC/postgresql.conf"
printf 'local all postgres peer\nhost all all 0.0.0.0/0 gss include_realm=0\n' > "$PGC/pg_hba.conf"
service postgresql start > /dev/null
su postgres -c "psql -qc 'CREATE ROLE alice LOGIN'"
printf '[mariadb]\nbind-address = 0.0.0.0\nplugin_load_add = auth_gssapi\ngssapi_keytab_path = /etc/mariadb.keytab\ngssapi_principal_name = mariadb/localhost@TEST.TABLEPRO\n' \
    > /etc/mysql/mariadb.conf.d/90-gssapi.cnf
service mariadb start > /dev/null
mariadb -e "CREATE USER alice IDENTIFIED VIA gssapi USING 'alice@TEST.TABLEPRO'"
echo READY
sleep infinity
EOF

echo "==> Building the KDC, PostgreSQL and MariaDB image"
docker build -q -t "$IMAGE" "$WORK_DIR/image" > /dev/null
docker run -d --name "$CONTAINER" \
    -p "127.0.0.1:$KDC_PORT:88/tcp" -p "127.0.0.1:$PG_PORT:5432" -p "127.0.0.1:$MARIADB_PORT:3306" \
    "$IMAGE" > /dev/null
for _ in $(seq 1 60); do
    docker logs "$CONTAINER" 2>&1 | grep READY > /dev/null && break
    sleep 2
done

cat > "$WORK_DIR/krb5.conf" << EOF
[libdefaults]
  default_realm = TEST.TABLEPRO
  dns_lookup_kdc = false
  dns_lookup_realm = false
  dns_canonicalize_hostname = false
  rdns = false
[realms]
  TEST.TABLEPRO = {
    kdc = tcp/127.0.0.1:$KDC_PORT
  }
[domain_realm]
  localhost = TEST.TABLEPRO
EOF

cat > "$WORK_DIR/client.c" << 'EOF'
#include <GSS/GSS.h>
#include <CoreFoundation/CoreFoundation.h>
#include <libpq-fe.h>
#include <mysql.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int ticket(const char *password, const char *cache) {
    OM_uint32 minor = 0;
    gss_buffer_desc buffer = { strlen("alice@TEST.TABLEPRO"), "alice@TEST.TABLEPRO" };
    gss_name_t name = GSS_C_NO_NAME;
    gss_import_name(&minor, &buffer, GSS_C_NT_USER_NAME, &name);
    CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    char cacheName[512];
    snprintf(cacheName, sizeof cacheName, "FILE:%s", cache);
    CFDictionarySetValue(attributes, kGSSICPassword, CFStringCreateWithCString(NULL, password, kCFStringEncodingUTF8));
    CFDictionarySetValue(attributes, kGSSICKerberosCacheName, CFStringCreateWithCString(NULL, cacheName, kCFStringEncodingUTF8));
    gss_cred_id_t cred = NULL;
    return gss_aapl_initial_cred(name, GSS_KRB5_MECHANISM, attributes, &cred, NULL) == 0 ? 0 : 1;
}

static void postgres(const char *label, const char *port, const char *mode) {
    char conninfo[256];
    snprintf(conninfo, sizeof conninfo,
             "host=localhost hostaddr=127.0.0.1 port=%s dbname=postgres user=alice sslmode=disable gssencmode=%s", port, mode);
    PGconn *conn = PQconnectdb(conninfo);
    if (PQstatus(conn) == CONNECTION_OK) {
        printf("%s|OK gssenc=%d\n", label, PQgssEncInUse(conn));
    } else {
        printf("%s|FAILED %s", label, PQerrorMessage(conn));
    }
    PQfinish(conn);
}

static void mariadb(const char *label, int port) {
    MYSQL *mysql = mysql_init(NULL);
    unsigned int protocol = MYSQL_PROTOCOL_TCP;
    my_bool off = 0;
    mysql_options(mysql, MYSQL_OPT_PROTOCOL, &protocol);
    mysql_options(mysql, MYSQL_OPT_SSL_ENFORCE, &off);
    mysql_options(mysql, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &off);
    if (mysql_real_connect(mysql, "localhost", "alice", NULL, NULL, port, NULL, 0)) {
        printf("%s|OK\n", label);
    } else {
        printf("%s|FAILED %s\n", label, mysql_error(mysql));
    }
    mysql_close(mysql);
}

int main(int argc, char **argv) {
    unsetenv("KRB5CCNAME");
    postgres("pg-no-ticket", argv[1], "disable");
    printf("wrong-password|%s\n", ticket("wrong", argv[3]) == 0 ? "ACCEPTED" : "REFUSED");
    if (ticket("alicepass", argv[3]) != 0) {
        printf("ticket|FAILED\n");
        return 1;
    }
    char environment[512];
    snprintf(environment, sizeof environment, "FILE:%s", argv[3]);
    setenv("KRB5CCNAME", environment, 1);
    postgres("pg-gss-require", argv[1], "require");
    postgres("pg-gss-disable", argv[1], "disable");
    mariadb("mariadb", atoi(argv[2]));
    return 0;
}
EOF

echo "==> Building the client against $LIBS_DIR ($ARCH)"
clang -arch "$ARCH" -Wno-deprecated-declarations \
    -I"$APPLE_DIR/Plugins/PostgreSQLDriverPlugin/CLibPQ/include" -I"$APPLE_DIR/Plugins/MySQLDriverPlugin/CMariaDB/include" \
    -o "$WORK_DIR/client" "$WORK_DIR/client.c" \
    "$LIBS_DIR/libpq_$ARCH.a" "$LIBS_DIR/libpgcommon_$ARCH.a" "$LIBS_DIR/libpgport_$ARCH.a" "$LIBS_DIR/libmariadb_$ARCH.a" \
    "$LIBS_DIR/libssl_$ARCH.a" "$LIBS_DIR/libcrypto_$ARCH.a" \
    -framework GSS -framework CoreFoundation -framework Security -lz -liconv

output="$(KRB5_CONFIG="$WORK_DIR/krb5.conf" "$WORK_DIR/client" "$PG_PORT" "$MARIADB_PORT" "$WORK_DIR/alice.ccache")"
echo "$output"

failures=0
expect() {
    if ! echo "$output" | grep -F "$1|$2" > /dev/null; then
        echo "FAIL: $1 did not report $2" >&2
        failures=$((failures + 1))
    fi
}
expect pg-no-ticket "FAILED"
expect wrong-password "REFUSED"
expect pg-gss-require "OK gssenc=1"
expect pg-gss-disable "OK gssenc=0"
expect mariadb "OK"

if [ "$failures" -ne 0 ]; then
    exit 1
fi
echo "OK: libpq and Connector/C sign in with Kerberos through the GSS framework."
