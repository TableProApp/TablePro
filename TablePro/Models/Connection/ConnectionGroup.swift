//
//  ConnectionGroup.swift
//  TablePro
//

import Foundation

/// A named group (folder) for organizing database connections
struct ConnectionGroup: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var color: ConnectionColor
    var parentId: UUID?
    var sortOrder: Int

    init(id: UUID = UUID(), name: String, color: ConnectionColor = .none, parentId: UUID? = nil, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.color = color
        self.parentId = parentId
        self.sortOrder = sortOrder
    }
}
