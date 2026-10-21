//
//  AppleIntelligenceAvailability.swift
//  TablePro
//

import Foundation

enum AppleIntelligenceAvailability: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case requiresNewerMacOS
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
        case unknown
    }

    case available
    case unavailable(Reason)

    static let displayName = "Apple Intelligence"
    static let providerID = "apple-intelligence"

    var isAvailable: Bool {
        self == .available
    }

    var unavailableExplanation: String? {
        guard case .unavailable(let reason) = self else { return nil }
        switch reason {
        case .requiresNewerMacOS:
            return String(localized: "Apple Intelligence needs macOS 26 or later.")
        case .deviceNotEligible:
            return String(localized: "This Mac does not support Apple Intelligence.")
        case .appleIntelligenceNotEnabled:
            return String(localized: "Turn on Apple Intelligence in System Settings > Apple Intelligence & Siri.")
        case .modelNotReady:
            return String(localized: "The Apple Intelligence model is still downloading.")
        case .unknown:
            return String(localized: "Apple Intelligence is not available on this Mac right now.")
        }
    }
}
