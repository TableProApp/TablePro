import Foundation
import TableProPluginKit
import TableProTeradataCore

enum TeradataSSLMapping {
    static func tlsOptions(for ssl: SSLConfiguration) -> TeradataTLSOptions {
        guard ssl.isEnabled else { return .disabled }
        return TeradataTLSOptions(
            enabled: true,
            allowPlaintextFallback: ssl.mode == .preferred,
            verifiesCertificate: ssl.verifiesCertificate,
            verifiesHostname: ssl.verifiesHostname,
            caCertificatePath: ssl.caCertificatePath,
            modeLabel: modeLabel(for: ssl.mode))
    }

    private static func modeLabel(for mode: SSLMode) -> String {
        switch mode {
        case .disabled: return "DISABLE"
        case .preferred: return "PREFER"
        case .required: return "REQUIRE"
        case .verifyCa: return "VERIFY-CA"
        case .verifyIdentity: return "VERIFY-FULL"
        }
    }
}
