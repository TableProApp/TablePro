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
        case .silent: return "lock.open"
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
}
