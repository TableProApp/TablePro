import Foundation
import TableProPluginKit
import TableProTeradataCore

internal enum TeradataSSLConfigurationError: Error, PluginDriverError {
    case verifyCaNeedsCertificate

    var pluginErrorMessage: String {
        switch self {
        case .verifyCaNeedsCertificate:
            return String(localized: "Verify CA needs a CA certificate. Choose the CA certificate that signed the server's certificate.")
        }
    }
}

enum TeradataSSLMapping {
    static func tlsOptions(for ssl: SSLConfiguration) throws -> TeradataTLSOptions {
        guard ssl.isEnabled else { return .disabled }
        if ssl.mode == .verifyCa, ssl.caCertificatePath.trimmingCharacters(in: .whitespaces).isEmpty {
            throw TeradataSSLConfigurationError.verifyCaNeedsCertificate
        }
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
