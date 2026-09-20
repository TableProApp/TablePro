import Foundation
import TableProModels

nonisolated enum SafeModeBadgeTint: Equatable, Sendable {
    case blocked
    case cautioned
}

nonisolated struct SafeModeBadge: Equatable, Sendable {
    let symbolName: String
    let title: String
    let tint: SafeModeBadgeTint

    init?(level: SafeModeLevel) {
        switch level {
        case .off:
            return nil
        case .readOnly:
            symbolName = "lock.fill"
            title = String(localized: "Read-Only")
            tint = .blocked
        case .confirmWrites:
            symbolName = "shield.fill"
            title = String(localized: "Confirm Writes")
            tint = .cautioned
        }
    }
}
