//
//  ConnectionGroup.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary

struct ConnectionGroup: Identifiable, Hashable, Codable {
    static let maxNestingDepth = LibraryGroupGraph.maxNestingDepth

    let id: UUID
    var name: String
    var color: ConnectionColor
    /// An SF Symbol the user picked to draw instead of the folder. Nil draws the folder.
    var iconName: String?
    var parentId: UUID?
    var sortOrder: Int

    init(
        id: UUID = UUID(),
        name: String,
        color: ConnectionColor = .none,
        iconName: String? = nil,
        parentId: UUID? = nil,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.iconName = iconName
        self.parentId = parentId
        self.sortOrder = sortOrder
    }
}
