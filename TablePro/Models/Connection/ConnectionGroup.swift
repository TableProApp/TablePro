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

/// The fields a person edits on a group, compared one by one so a save writes only what changed.
struct ConnectionGroupFields: Equatable {
    var name: String
    var color: ConnectionColor
    var iconName: String?
    var parentId: UUID?

    init(name: String, color: ConnectionColor = .none, iconName: String? = nil, parentId: UUID? = nil) {
        self.name = name
        self.color = color
        self.iconName = iconName
        self.parentId = parentId
    }

    init(_ group: ConnectionGroup) {
        self.init(name: group.name, color: group.color, iconName: group.iconName, parentId: group.parentId)
    }
}
