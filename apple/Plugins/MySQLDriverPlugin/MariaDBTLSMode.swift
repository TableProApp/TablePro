import CMariaDB
import Foundation
import TableProPluginKit

// The SSL mode as Connector/C options. MYSQL_OPT_SSL_ENFORCE alone falls back to plaintext when the
// server offers no TLS (mariadb_lib.c:3643, my_auth.c:319-338), so only Preferred is left with that.
enum MariaDBTLSMode {
    static func apply(
        _ mode: SSLMode,
        serverName: MariaDBTLSServerName?,
        to handle: UnsafeMutablePointer<MYSQL>
    ) {
        switch mode {
        case .disabled, .preferred:
            var enforce: my_bool = mode == .disabled ? 0 : 1
            var verify: my_bool = 0
            mysql_options(handle, MYSQL_OPT_SSL_ENFORCE, &enforce)
            mysql_options(handle, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &verify)
        case .required:
            tablepro_mysql_require_tls_without_verification(handle)
        case .verifyCa:
            tablepro_mysql_require_trusted_chain(handle)
        case .verifyIdentity:
            tablepro_mysql_require_server_identity(handle)
        }
        if let serverName, SSLConfiguration(mode: mode).verifiesCertificate {
            tablepro_mysql_set_tunneled_server_name(handle, serverName.pointer)
        }
    }

    // A socket never leaves this Mac, so only a TCP dial to a tunnel's forward checks another server's name.
    static func serverName(for config: DriverConnectionConfig, transport: MySQLTransport) -> String? {
        transport.isUnixSocket ? nil : config.tunneledServerName
    }

    static func killConnectionMode(_ mode: SSLMode, sessionUsedTLS: Bool) -> SSLMode {
        guard sessionUsedTLS else { return .disabled }
        return mode == .preferred ? .required : mode
    }
}

// The C string the verification callback reads during every handshake on a handle, so it lives as long as the
// connection that opens them.
final class MariaDBTLSServerName: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<CChar>

    init?(_ name: String?) {
        guard let name, !name.isEmpty, let copy = strdup(name) else { return nil }
        pointer = copy
    }

    deinit {
        free(pointer)
    }
}
