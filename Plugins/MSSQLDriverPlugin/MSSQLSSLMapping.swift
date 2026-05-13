import Foundation
import TableProPluginKit

/// FreeTDS dblib reads this value via DBSETENCRYPT. Accepted values come from
/// libtds: "off", "request", "require", "strict". Cert verification beyond what
/// the system trust store provides is configured in freetds.conf, not per
/// connection through dblib, so .verifyCa and .verifyIdentity both map to
/// "require"; the actual verification depends on the trust store and any
/// freetds.conf overrides on the machine.
enum MSSQLSSLMapping {
    static func freetdsEncryptionFlag(for mode: SSLMode) -> String {
        switch mode {
        case .disabled: return "off"
        case .preferred: return "request"
        case .required, .verifyCa, .verifyIdentity: return "require"
        }
    }
}
