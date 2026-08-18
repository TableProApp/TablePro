//
//  FavoriteDatabaseEnvironmentFilter.swift
//  TablePro
//

import Foundation

internal enum FavoriteDatabaseEnvironmentFilter: String, CaseIterable, Sendable {
    case all
    case development
    case testing
    case production
    case unassigned

    internal var title: String {
        switch self {
        case .all: String(localized: "All Environments")
        case .development: FavoriteDatabaseEnvironment.development.title
        case .testing: FavoriteDatabaseEnvironment.testing.title
        case .production: FavoriteDatabaseEnvironment.production.title
        case .unassigned: FavoriteDatabaseEnvironment.none.title
        }
    }

    internal var environment: FavoriteDatabaseEnvironment? {
        switch self {
        case .all: nil
        case .development: .development
        case .testing: .testing
        case .production: .production
        case .unassigned: FavoriteDatabaseEnvironment.none
        }
    }
}
