import Foundation
import TableProPluginKit
import TableProTeradataCore

struct TeradataConnectTimeout: Equatable, Sendable {
    static let defaultMilliseconds = 20_000
    static let maximumMilliseconds = 3_600_000

    let milliseconds: Int

    init(additionalFields: [String: String]) {
        if let raw = additionalFields["connectTimeoutMilliseconds"] {
            milliseconds = Self.parseMilliseconds(raw) ?? Self.defaultMilliseconds
            return
        }
        if let raw = additionalFields["connectTimeoutSeconds"] {
            milliseconds = Self.parseSeconds(raw) ?? Self.defaultMilliseconds
            return
        }
        milliseconds = Self.defaultMilliseconds
    }

    private static func parseMilliseconds(_ raw: String) -> Int? {
        guard let value = Int64(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        return clamp(value)
    }

    private static func parseSeconds(_ raw: String) -> Int? {
        guard let seconds = Int64(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        let multiplied = seconds.multipliedReportingOverflow(by: 1_000)
        let milliseconds = multiplied.overflow ? (seconds > 0 ? Int64.max : Int64.min) : multiplied.partialValue
        return clamp(milliseconds)
    }

    private static func clamp(_ milliseconds: Int64) -> Int {
        Int(min(max(milliseconds, 1), Int64(maximumMilliseconds)))
    }
}

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
