#ifndef CMariaDB_h
#define CMariaDB_h

#include <mysql.h>
#include <errmsg.h>
#include <ma_pvio.h>
// ma_pvio.h stands MARIADB_TLS in for void when HAVE_TLS is unset; ma_tls.h declares the struct.
#undef MARIADB_TLS
#include <ma_tls.h>

// Clears the status the way the library's own skip does: a status left set fails the
// sign-in after the server accepts it.
static int tablepro_mysql_accept_any_certificate(MARIADB_TLS *ctls, unsigned int flags) {
    (void)flags;
    if (ctls != NULL && ctls->pvio != NULL && ctls->pvio->mysql != NULL) {
        ctls->pvio->mysql->net.tls_verify_status = 0;
    }
    return 0;
}

// MYSQL_OPT_SSL_ENFORCE alone falls back to plaintext. A required verification refuses a server
// without TLS before any credential is sent, and the callback then skips the certificate check.
static inline void tablepro_mysql_require_tls_without_verification(MYSQL *mysql) {
    my_bool verify = 1;
    mysql_optionsv(mysql, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &verify);
    mysql_optionsv(mysql, MARIADB_OPT_TLS_VERIFICATION_CALLBACK, tablepro_mysql_accept_any_certificate);
}

#endif
