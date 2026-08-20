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
        guard let environment else { return String(localized: "All Environments") }
        return environment.title
    }

    internal var environment: FavoriteDatabaseEnvironment? {
        switch self {
        case .all: nil
        case .development: .development
        case .testing: .testing
        case .production: .production
        case .unassigned: .unassigned
        }
    }
}
