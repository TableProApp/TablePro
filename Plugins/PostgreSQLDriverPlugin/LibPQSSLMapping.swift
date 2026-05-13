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
}
