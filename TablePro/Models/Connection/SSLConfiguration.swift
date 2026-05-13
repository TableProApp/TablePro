import Foundation
import TableProPluginKit

typealias SSLConfiguration = TableProPluginKit.SSLConfiguration
typealias SSLMode = TableProPluginKit.SSLMode

extension SSLMode: @retroactive Identifiable {
    public var id: String { rawValue }

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
