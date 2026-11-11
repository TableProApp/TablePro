import Foundation
import TableProPluginKit

enum LibPQSSLMapping {
    static func sslmode(for mode: SSLMode) -> String {
        switch mode {
        case .disabled: return "disable"
        case .preferred: return "prefer"
        case .required: return "require"
        case .verifyCa: return "verify-ca"
        case .verifyIdentity: return "verify-full"
        }
    }

    // libpq's own text suggests sslrootcert=system, which TablePro does not offer and libpq refuses under verify-ca.
    static func missingRootCertificateError(_ message: String, sslConfig: SSLConfiguration) -> LibPQPluginError? {
        guard sslConfig.mode == .verifyCa, sslConfig.caCertificatePath.isEmpty else { return nil }
        let lowered = message.lowercased()
        guard lowered.contains("root certificate file"), lowered.contains("does not exist") else { return nil }
        return LibPQPluginError(
            message: String(
                localized: """
                    Verify CA needs the server's CA certificate. Choose it under SSL, or use Verify Identity to check \
                    the server against this Mac's trusted certificates.
                    """
            ),
            sqlState: nil,
            detail: nil
        )
    }
}
