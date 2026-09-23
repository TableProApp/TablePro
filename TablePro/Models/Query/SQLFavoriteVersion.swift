//
//  SQLFavoriteVersion.swift
//  TablePro
//

import Foundation

internal struct SQLFavoriteVersion: Identifiable, Hashable, Sendable {
    let id: Int64
    let favoriteId: UUID
    let name: String
    let query: String
    let savedAt: Date
}
