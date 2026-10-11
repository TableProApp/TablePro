//
//  TableFolderDropResolver.swift
//  TablePro
//

import Foundation

/// One table or view being dragged, with the folder it sits in now.
internal struct TableFolderDragItem: Hashable, Sendable {
    internal let name: String
    internal let scope: DatabaseScope
    internal let folderId: UUID?
}

/// Where a drag can land. A folder files the objects into it; a kind section takes them out of
/// whatever folder they are in.
internal enum TableFolderDropTarget: Equatable, Sendable {
    case folder(TableFolder)
    case unfiled(DatabaseScope)
}

internal enum TableFolderDropOperation: Equatable, Sendable {
    case file(names: [String], scope: DatabaseScope, folderId: UUID)
    case unfile(names: [String], scope: DatabaseScope)
}

/// Decides what a drop does, or that it does nothing.
///
/// A drag that reaches outside the target's database or schema is refused whole rather than half
/// applied: a folder belongs to one container, and moving only the objects that happen to share it
/// would leave the rest where they were with nothing on screen saying why.
internal enum TableFolderDropResolver {
    internal static func resolve(
        items: [TableFolderDragItem],
        target: TableFolderDropTarget
    ) -> TableFolderDropOperation? {
        guard !items.isEmpty else { return nil }
        switch target {
        case .folder(let folder):
            guard items.allSatisfy({ $0.scope == folder.scope }) else { return nil }
            let moving = items.filter { $0.folderId != folder.id }
            guard !moving.isEmpty else { return nil }
            return .file(names: moving.map(\.name).sorted(), scope: folder.scope, folderId: folder.id)
        case .unfiled(let scope):
            guard items.allSatisfy({ $0.scope == scope }) else { return nil }
            let filed = items.filter { $0.folderId != nil }
            guard !filed.isEmpty else { return nil }
            return .unfile(names: filed.map(\.name).sorted(), scope: scope)
        }
    }
}
