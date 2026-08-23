//
//  FavoriteDatabaseGroup.swift
//  TablePro
//

import Foundation

internal struct FavoriteDatabaseGroup: Equatable, Identifiable, Sendable {
    internal let environment: FavoriteDatabaseEnvironment
    internal let entries: [FavoriteDatabaseEntry]

    internal var id: String { environment.rawValue }
}
