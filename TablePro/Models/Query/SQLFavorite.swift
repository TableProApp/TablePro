//
//  SQLFavorite.swift
//  TablePro
//

import Foundation
import TableProImport

internal struct SQLFavorite: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var query: String
    var keyword: String?
    var folderId: UUID?
    var connectionId: UUID?
    var sortOrder: Int
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        query: String,
        keyword: String? = nil,
        folderId: UUID? = nil,
        connectionId: UUID? = nil,
        sortOrder: Int = 0,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        let now = Date()
        self.id = id
        self.name = name
        self.query = query
        self.keyword = keyword
        self.folderId = folderId
        self.connectionId = connectionId
        self.sortOrder = sortOrder
        self.createdAt = createdAt ?? now
        self.updatedAt = updatedAt ?? now
    }

    static func autoName(from query: String) -> String {
        SavedQueryName.derived(from: query)
    }
}

internal extension SQLFavorite {
    var ledgerEntry: SavedQueryLedger.Entry {
        SavedQueryLedger.Entry(name: name, sql: query, keyword: keyword, connectionId: connectionId)
    }
}
