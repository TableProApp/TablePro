// One connect with the TLS options an app's CMariaDB.h sets for an SSL mode; -DTABLEPRO_IOS picks the iOS header.
// usage: tls-client <host> <port> <disabled|preferred|required|verify-ca|verify-identity> <secret> [ca|-] [server-name]

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef TABLEPRO_IOS
#include "../../../TableProMobile/TableProMobile/CBridges/CMariaDB/CMariaDB.h"
#else
#include "../../../Plugins/MySQLDriverPlugin/CMariaDB/CMariaDB.h"
#endif

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: tls-client <host> <port> <mode> <secret> [ca|-] [server-name]\n");
        return 2;
    }
    const char *host = argv[1];
    unsigned int port = (unsigned int)atoi(argv[2]);
    const char *mode = argv[3];
    const char *secret = argv[4];
    const char *ca = argc > 5 && strcmp(argv[5], "-") != 0 ? argv[5] : NULL;
    const char *server_name = argc > 6 ? argv[6] : NULL;

    MYSQL *mysql = mysql_init(NULL);
    unsigned int timeout = 5;
    unsigned int tcp = MYSQL_PROTOCOL_TCP;
    mysql_options(mysql, MYSQL_OPT_CONNECT_TIMEOUT, &timeout);
    mysql_options(mysql, MYSQL_OPT_PROTOCOL, &tcp);

    my_bool on = 1;
    my_bool off = 0;
    if (strcmp(mode, "disabled") == 0 || strcmp(mode, "preferred") == 0) {
        mysql_options(mysql, MYSQL_OPT_SSL_ENFORCE, strcmp(mode, "preferred") == 0 ? &on : &off);
        mysql_options(mysql, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &off);
        // MySQLPlaintextPassword.methodsWithoutTLS, which both apps set on a session that may run without TLS.
        mysql_optionsv(mysql, MARIADB_OPT_RESTRICTED_AUTH,
                       "mysql_native_password,caching_sha2_password,sha256_password,mysql_old_password,"
                       "client_ed25519,parsec,auth_gssapi_client");
    } else if (strcmp(mode, "required") == 0) {
        tablepro_mysql_require_tls_without_verification(mysql);
    } else if (strcmp(mode, "verify-ca") == 0) {
        tablepro_mysql_require_trusted_chain(mysql);
    } else if (strcmp(mode, "verify-identity") == 0) {
#ifdef TABLEPRO_IOS
        tablepro_mysql_require_server_identity(mysql);
#else
        mysql_options(mysql, MYSQL_OPT_SSL_ENFORCE, &on);
        mysql_options(mysql, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &on);
#endif
    } else {
        fprintf(stderr, "unknown mode %s\n", mode);
        return 2;
    }
#ifdef TABLEPRO_IOS
    if (server_name != NULL) {
        tablepro_mysql_set_tunneled_server_name(mysql, server_name);
    }
#else
    (void)server_name;
#endif
    if (ca != NULL) {
        mysql_options(mysql, MYSQL_OPT_SSL_CA, ca);
    }

    MYSQL *connected = mysql_real_connect(mysql, host, "app", secret, NULL, port, NULL, 0);
    const char *cipher = connected != NULL ? mysql_get_ssl_cipher(mysql) : NULL;
    printf("connected=%d errno=%u tls=%d error=%s\n", connected != NULL, mysql_errno(mysql), cipher != NULL,
           mysql_error(mysql));
    mysql_close(mysql);
    return 0;
}
