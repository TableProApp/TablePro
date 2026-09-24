import Foundation
import TableProMSSQLCore
import TableProPluginKit

/// The FreeTDS encryption level and certificate checks behind each SSL mode. libtds reads both from the connection's
/// freetds.conf entry and from nowhere else; see MSSQLFreeTDSServerEntry.
///
/// Disabled asks for `request`, as SQL Server's own drivers do with encryption off: the login is encrypted and the rest
/// of the session is not, unless the server forces encryption.
enum MSSQLSSLMapping {
    static func encryptionLevel(for mode: SSLMode) -> MSSQLEncryptionLevel {
        switch mode {
        case .disabled, .preferred: return .request
        case .required, .verifyCa, .verifyIdentity: return .require
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
