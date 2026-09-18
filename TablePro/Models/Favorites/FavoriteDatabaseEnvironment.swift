//
//  FavoriteDatabaseEnvironment.swift
//  TablePro
//

import Foundation

/// One name per bucket. The group header, the filter and both menus all read `title`, because a
/// second spelling for the same bucket reads as a second bucket and costs a second translation.
internal enum FavoriteDatabaseEnvironment: String, CaseIterable, Codable, Sendable {
    case development
    case testing
    case production
    case unassigned

    internal var title: String {
        switch self {
        case .development: String(localized: "Development")
        case .testing: String(localized: "Testing")
        case .production: String(localized: "Production")
        case .unassigned: String(localized: "Unassigned")
        }
    }

    internal var iconName: String {
        switch self {
        case .development: "wrench.and.screwdriver"
        case .testing: "checkmark.circle"
        case .production: "lock.shield"
        case .unassigned: "tray"
        }
    }
}
