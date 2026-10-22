import CMariaDB
import TableProPluginKit

// The SSL mode as Connector/C options. MYSQL_OPT_SSL_ENFORCE alone falls back to plaintext when the
// server offers no TLS (mariadb_lib.c:3643, my_auth.c:319-338), so only Preferred is left with that.
enum MariaDBTLSMode {
    static func apply(_ mode: SSLMode, to handle: UnsafeMutablePointer<MYSQL>) {
        switch mode {
        case .disabled, .preferred, .verifyIdentity:
            var enforce: my_bool = mode == .disabled ? 0 : 1
            var verify: my_bool = mode == .verifyIdentity ? 1 : 0
            mysql_options(handle, MYSQL_OPT_SSL_ENFORCE, &enforce)
            mysql_options(handle, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &verify)
        case .required:
            tablepro_mysql_require_tls_without_verification(handle)
        case .verifyCa:
            tablepro_mysql_require_trusted_chain(handle)
        }
    }

    static func killConnectionMode(_ mode: SSLMode, sessionUsedTLS: Bool) -> SSLMode {
        guard sessionUsedTLS else { return .disabled }
        return mode == .preferred ? .required : mode
    }
}
