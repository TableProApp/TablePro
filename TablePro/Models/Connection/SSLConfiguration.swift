//
//  SSLConfiguration.swift
//  TablePro
//

import Foundation
/// SSL/TLS connection mode
enum SSLMode: String, CaseIterable, Identifiable, Codable {
    case disabled = "Disabled"
    case preferred = "Preferred"
    case required = "Required"
    case verifyCa = "Verify CA"
    case verifyIdentity = "Verify Identity"

    var id: String { rawValue }

    /// User-facing picker label that clarifies the actual behavior.
    var displayLabel: String {
        switch self {
        case .disabled: return String(localized: "Disabled")
        case .preferred: return String(localized: "Preferred")
        case .required: return String(localized: "Required (skip verify)")
        case .verifyCa: return String(localized: "Verify CA")
        case .verifyIdentity: return String(localized: "Verify Identity")
        }
    }

    var description: String {
        switch self {
        case .disabled: return String(localized: "No SSL encryption")
        case .preferred: return String(localized: "Use SSL if available")
        case .required: return String(localized: "Require SSL, skip verification")
        case .verifyCa: return String(localized: "Verify server certificate")
        case .verifyIdentity: return String(localized: "Verify certificate and hostname")
        }
    }
}

/// SSL/TLS configuration for database connections
struct SSLConfiguration: Codable, Hashable {
    var mode: SSLMode = .disabled
    var caCertificatePath: String = ""
    var clientCertificatePath: String = ""
    var clientKeyPath: String = ""

    /// Whether SSL is effectively enabled
    var isEnabled: Bool { mode != .disabled }

    /// Whether certificate verification is enabled
    var verifiesCertificate: Bool { mode == .verifyCa || mode == .verifyIdentity }
}
