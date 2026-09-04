//
//  SafeModeLevel.swift
//  TablePro
//

import SwiftUI

internal enum SafeModeLevel: String, Codable, CaseIterable, Identifiable {
    case silent = "silent"
    case alert = "alert"
    case alertFull = "alertFull"
    case safeMode = "safeMode"
    case safeModeFull = "safeModeFull"
    case readOnly = "readOnly"
}

internal extension SafeModeLevel {
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .silent: return String(localized: "Silent")
        case .alert: return String(localized: "Alert")
        case .alertFull: return String(localized: "Alert (Full)")
        case .safeMode: return String(localized: "Safe Mode")
        case .safeModeFull: return String(localized: "Safe Mode (Full)")
        case .readOnly: return String(localized: "Read-Only")
        }
    }

    var blocksAllWrites: Bool {
        self == .readOnly
    }

    /// How much this level gates, as a monotonic rank. Used only by `raised(toFloor:)`, because a
    /// floor has to know which of two levels asks more of the user. Nothing else orders these:
    /// `alertFull` and `safeMode` gate different things (every query versus authentication), and
    /// comparing them for any other purpose would be reading meaning into this number that is
    /// not there.
    private var gatingRank: Int {
        switch self {
        case .silent: return 0
        case .alert: return 1
        case .alertFull: return 2
        case .safeMode: return 3
        case .safeModeFull: return 4
        case .readOnly: return 5
        }
    }

    /// This level, or the floor if the floor asks more. A minimum, never a maximum: a user who
    /// deliberately chose `.readOnly` keeps read-only, and one who chose `.safeModeFull` is not
    /// dropped to `.alert`. Pure, so nothing is written to the connection and nothing has to be
    /// restored after a crash: whatever turned the floor on turning off is enough.
    func raised(toFloor floor: SafeModeLevel) -> SafeModeLevel {
        gatingRank < floor.gatingRank ? floor : self
    }

    var requiresConfirmation: Bool {
        switch self {
        case .alert, .alertFull, .safeMode, .safeModeFull: return true
        case .silent, .readOnly: return false
        }
    }

    var requiresAuthentication: Bool {
        switch self {
        case .safeMode, .safeModeFull: return true
        case .silent, .alert, .alertFull, .readOnly: return false
        }
    }

    var appliesToAllQueries: Bool {
        switch self {
        case .alertFull, .safeModeFull: return true
        case .silent, .alert, .safeMode, .readOnly: return false
        }
    }

    var iconName: String {
        switch self {
        case .silent: return "lock.open.fill"
        case .alert: return "exclamationmark.triangle"
        case .alertFull: return "exclamationmark.triangle.fill"
        case .safeMode: return "lock.shield"
        case .safeModeFull: return "lock.shield.fill"
        case .readOnly: return "lock.fill"
        }
    }

    var badgeColor: Color {
        switch self {
        case .silent: return .secondary
        case .alert, .alertFull: return .orange
        case .safeMode, .safeModeFull, .readOnly: return .red
        }
    }

    static func from(urlInteger value: Int) -> SafeModeLevel? {
        switch value {
        case 0: return .silent
        case 1: return .alert
        case 2: return .readOnly
        default: return nil
        }
    }
}
