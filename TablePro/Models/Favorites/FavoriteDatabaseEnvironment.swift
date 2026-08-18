//
//  FavoriteDatabaseEnvironment.swift
//  TablePro
//

import Foundation

internal enum FavoriteDatabaseEnvironment: String, CaseIterable, Codable, Sendable {
    case development
    case testing
    case production
    case none

    internal var title: String {
        switch self {
        case .development: String(localized: "Development")
        case .testing: String(localized: "Testing")
        case .production: String(localized: "Production")
        case .none: String(localized: "Unassigned")
        }
    }

    internal var menuTitle: String {
        switch self {
        case .none: String(localized: "No Environment")
        case .development, .testing, .production: title
        }
    }

    internal var iconName: String {
        switch self {
        case .development: "wrench.and.screwdriver"
        case .testing: "checkmark.circle"
        case .production: "lock.shield"
        case .none: "tray"
        }
    }
}
