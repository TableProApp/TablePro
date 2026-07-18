import Foundation
import TableProPluginKit
import TableProTrinoCore

enum TrinoSSLMapping {
    static func tlsOptions(for ssl: SSLConfiguration) -> TrinoTLSOptions {
        switch ssl.mode {
        case .disabled, .preferred, .required:
            return TrinoTLSOptions(mode: .insecure)
        case .verifyCa:
            return TrinoTLSOptions(mode: .caOnly, caCertificatePath: ssl.caCertificatePath)
        case .verifyIdentity:
            return TrinoTLSOptions(mode: .full, caCertificatePath: ssl.caCertificatePath)
        }
    }
}
