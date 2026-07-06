//
//  LicenseTier.swift
//  TablePro
//
//  Subscription tier a license belongs to, used to gate tier-specific features
//

import Foundation

/// The subscription tier carried by a license. A higher tier unlocks everything a lower tier does.
internal enum LicenseTier: Equatable {
    case starter
    case team
    case unknown(String)

    init(rawValue: String) {
        switch rawValue.trimmingCharacters(in: .whitespaces).lowercased() {
        case "", "starter":
            self = .starter
        case "team":
            self = .team
        default:
            self = .unknown(rawValue)
        }
    }

    /// Whether this tier unlocks a feature that requires `required`.
    func unlocks(_ required: LicenseTier) -> Bool {
        rank >= required.rank
    }

    var displayName: String {
        switch self {
        case .starter:
            return String(localized: "Starter")
        case .team:
            return String(localized: "Team")
        case .unknown(let raw):
            return raw.capitalized
        }
    }

    /// An unrecognized but server-validated tier ranks above all known tiers, so a future
    /// paid tier is never wrongly restricted by an older app build.
    private var rank: Int {
        switch self {
        case .starter:
            return 0
        case .team:
            return 1
        case .unknown:
            return .max
        }
    }
}
