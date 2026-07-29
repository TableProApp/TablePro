import Foundation
import TableProPluginKit
import TableProTrinoCore

enum TrinoSSLMapping {
    static func tlsOptions(for ssl: SSLConfiguration) -> TrinoTLSOptions {
        let mode: TrinoTLSOptions.VerificationMode
        switch ssl.mode {
        case .disabled, .preferred, .required:
            mode = .insecure
        case .verifyCa:
            mode = .caOnly
        case .verifyIdentity:
            mode = .full
        }
        return TrinoTLSOptions(
            mode: mode,
            caCertificatePath: ssl.caCertificatePath,
            clientCertificatePath: ssl.clientCertificatePath,
            clientKeyPath: ssl.clientKeyPath
        )
    }
}
