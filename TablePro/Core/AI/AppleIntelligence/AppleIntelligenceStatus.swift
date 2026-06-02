//
//  AppleIntelligenceStatus.swift
//  TablePro
//

import Foundation

enum AppleIntelligenceStatus: Sendable, Equatable {
    case available
    case osNotSupported
    case deviceNotEligible
    case notEnabled
    case modelNotReady
    case unknown

    var isAvailable: Bool { self == .available }

    var canOpenSystemSettings: Bool { self == .notEnabled }

    var statusText: String {
        switch self {
        case .available:
            return String(localized: "On-device. No API key, no network.")
        case .osNotSupported:
            return String(localized: "Requires macOS 26 or later.")
        case .deviceNotEligible:
            return String(localized: "Not available on this Mac. Apple Intelligence needs Apple silicon.")
        case .notEnabled:
            return String(localized: "Turn on Apple Intelligence in System Settings to use this.")
        case .modelNotReady:
            return String(localized: "The on-device model is still downloading. This finishes in the background.")
        case .unknown:
            return String(localized: "Apple Intelligence is not available right now.")
        }
    }
}
