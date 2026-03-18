//
//  SQLFavoriteFolder.swift
//  TablePro
//

import Foundation

/// A folder for organizing SQL favorites into a hierarchy
internal struct SQLFavoriteFolder: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var parentId: UUID?
    var connectionId: UUID?
    var sortOrder: Int
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        parentId: UUID? = nil,
        connectionId: UUID? = nil,
        sortOrder: Int = 0,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        let now = Date()
        self.id = id
        self.name = name
        self.parentId = parentId
        self.connectionId = connectionId
        self.sortOrder = sortOrder
        self.createdAt = createdAt ?? now
        self.updatedAt = updatedAt ?? now
    }
}
