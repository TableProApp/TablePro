#ifndef CMariaDB_h
#define CMariaDB_h

#include "include/mysql.h"
#include "include/ma_pvio.h"
#include "include/mysqld_error.h"
// ma_pvio.h stands MARIADB_TLS in for void when HAVE_TLS is unset; ma_tls.h declares the struct.
#undef MARIADB_TLS
#include "include/ma_tls.h"

static inline my_bool tablepro_mysql_set_io_timeout(MYSQL *mysql, unsigned int seconds) {
    if (mysql == NULL || mysql->net.pvio == NULL) {
        return 1;
    }
    mysql->options.read_timeout = seconds;
    mysql->options.write_timeout = seconds;
    my_bool read_result = ma_pvio_set_timeout(mysql->net.pvio, PVIO_READ_TIMEOUT, (int)seconds);
    my_bool write_result = ma_pvio_set_timeout(mysql->net.pvio, PVIO_WRITE_TIMEOUT, (int)seconds);
    return read_result || write_result;
}

// The server name a tunneled connection's certificate is checked against, kept as handle user data.
static const char *const tablepro_mysql_server_name_key = "com.TablePro.tls.serverName";

// Clears the status the way the library's own skip does: a status left set fails the
// sign-in after the server accepts it.
static int tablepro_mysql_accept_any_certificate(MARIADB_TLS *ctls, unsigned int flags) {
    (void)flags;
    if (ctls != NULL && ctls->pvio != NULL && ctls->pvio->mysql != NULL) {
        ctls->pvio->mysql->net.tls_verify_status = 0;
    }
    return 0;
}

static const char *tablepro_mysql_server_name(MYSQL *mysql) {
    void *name = NULL;
    mysql_get_optionv(mysql, MARIADB_OPT_USERDATA, (void *)tablepro_mysql_server_name_key, &name);
    return (const char *)name;
}

// Connector/C skips the host check and forgives an untrusted certificate on a 127.0.0.1 dial
// (my_auth.c is_local_connection). Behind a tunnel that dial is not local, so a failure is raised
// past MARIADB_TLS_VERIFY_AUTO, which my_auth.c then refuses instead of clearing.
static int tablepro_mysql_refuse_on_tunnel(MYSQL *mysql, int failed) {
    if (failed && tablepro_mysql_server_name(mysql) != NULL) {
        mysql->net.tls_verify_status |= MARIADB_TLS_VERIFY_ERROR;
    }
    return failed;
}

static int tablepro_mysql_verify_chain(MARIADB_TLS *ctls, unsigned int flags) {
    if (ctls == NULL || ctls->pvio == NULL || ctls->pvio->mysql == NULL) {
        return 1;
    }
    int failed = ma_pvio_tls_verify_server_cert(ctls, flags & ~MARIADB_TLS_VERIFY_HOST);
    return tablepro_mysql_refuse_on_tunnel(ctls->pvio->mysql, failed);
}

// Runs the library's own check with the server's name in place of the tunnel's 127.0.0.1.
static int tablepro_mysql_verify_identity(MARIADB_TLS *ctls, unsigned int flags) {
    if (ctls == NULL || ctls->pvio == NULL || ctls->pvio->mysql == NULL) {
        return 1;
    }
    MYSQL *mysql = ctls->pvio->mysql;
    const char *server_name = tablepro_mysql_server_name(mysql);
    if (server_name == NULL) {
        return ma_pvio_tls_verify_server_cert(ctls, flags);
    }
    char *dialed = mysql->host;
    mysql->host = (char *)server_name;
    int failed = ma_pvio_tls_verify_server_cert(ctls, flags | MARIADB_TLS_VERIFY_HOST);
    mysql->host = dialed;
    return tablepro_mysql_refuse_on_tunnel(mysql, failed);
}

static inline void tablepro_mysql_verify_server_certificate(MYSQL *mysql, int (*callback)(MARIADB_TLS *, unsigned int)) {
    my_bool enforce = 1;
    my_bool verify = 1;
    mysql_optionsv(mysql, MYSQL_OPT_SSL_ENFORCE, &enforce);
    mysql_optionsv(mysql, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &verify);
    mysql_optionsv(mysql, MARIADB_OPT_TLS_VERIFICATION_CALLBACK, callback);
}

// MYSQL_OPT_SSL_ENFORCE alone falls back to plaintext. A required verification refuses a server
// without TLS before any credential is sent, and the callback then skips the certificate check.
static inline void tablepro_mysql_require_tls_without_verification(MYSQL *mysql) {
    tablepro_mysql_verify_server_certificate(mysql, tablepro_mysql_accept_any_certificate);
}

// Verify CA: the library also checks the host name on every dial but a local one.
static inline void tablepro_mysql_require_trusted_chain(MYSQL *mysql) {
    tablepro_mysql_verify_server_certificate(mysql, tablepro_mysql_verify_chain);
}

static inline void tablepro_mysql_require_server_identity(MYSQL *mysql) {
    tablepro_mysql_verify_server_certificate(mysql, tablepro_mysql_verify_identity);
}

// `name` must outlive every TLS handshake on the handle.
static inline void tablepro_mysql_set_tunneled_server_name(MYSQL *mysql, const char *name) {
    mysql_optionsv(mysql, MARIADB_OPT_USERDATA, (void *)tablepro_mysql_server_name_key, (void *)name);
}

#endif
