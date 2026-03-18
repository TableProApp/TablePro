//
//  SQLFavorite.swift
//  TablePro
//

import Foundation

/// A saved SQL query that can be quickly recalled and optionally expanded via keyword
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
}
