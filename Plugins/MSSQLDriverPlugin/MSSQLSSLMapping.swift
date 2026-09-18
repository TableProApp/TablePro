import Foundation
import TableProMSSQLCore
import TableProPluginKit

/// FreeTDS dblib reads the encryption level via DBSETENCRYPT. Accepted values come from libtds:
/// "off", "request", "require", "strict". Certificate validation is not reachable through dblib
/// at all, so a verifying mode also produces a generated freetds.conf; see MSSQLFreeTDSConfig.
enum MSSQLSSLMapping {
    static func freetdsEncryptionFlag(for mode: SSLMode) -> String {
        switch mode {
        case .disabled: return "off"
        case .preferred: return "request"
        case .required, .verifyCa, .verifyIdentity: return "require"
        }
    }

    static func certificateVerification(for mode: SSLMode) -> MSSQLCertificateVerification {
        switch mode {
        case .disabled, .preferred, .required: return .none
        case .verifyCa: return .chain
        case .verifyIdentity: return .chainAndHostname
        }
    }
}
