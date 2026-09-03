//
//  ExportOutlineNode.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// One row of the export tree. `NSOutlineView` identifies its items by object identity, so these
/// are reference types rebuilt only when the shape of the tree changes, never on a checkbox toggle.
internal final class ExportOutlineNode {
    internal enum Kind {
        case database(databaseID: UUID)
        case group(databaseID: UUID, objectKind: PluginExportObjectKind)
        case object(databaseID: UUID, objectID: UUID)
    }

    internal let kind: Kind
    internal private(set) var children: [ExportOutlineNode]

    internal init(kind: Kind, children: [ExportOutlineNode] = []) {
        self.kind = kind
        self.children = children
    }

    internal var isLeaf: Bool { children.isEmpty }

    /// A stable key for the node's place in the tree, so expansion survives a rebuild that object
    /// identity alone would lose.
    internal var identity: String {
        switch kind {
        case .database(let databaseID):
            return "db:\(databaseID.uuidString)"
        case .group(let databaseID, let objectKind):
            return "group:\(databaseID.uuidString):\(objectKind.rawValue)"
        case .object(let databaseID, let objectID):
            return "obj:\(databaseID.uuidString):\(objectID.uuidString)"
        }
    }
}

internal enum ExportOutlineTreeBuilder {
    /// Groups a database's objects by kind, in dump order. A database whose objects are all one
    /// kind skips the group level: a MySQL schema with only tables should not make the user open a
    /// "Tables" folder to reach them.
    internal static func build(from databases: [ExportDatabaseItem]) -> [ExportOutlineNode] {
        databases.map { database in
            let kinds = database.presentKinds
            guard kinds.count > 1 else {
                return ExportOutlineNode(
                    kind: .database(databaseID: database.id),
                    children: database.objects.map {
                        ExportOutlineNode(kind: .object(databaseID: database.id, objectID: $0.id))
                    }
                )
            }
            return ExportOutlineNode(
                kind: .database(databaseID: database.id),
                children: kinds.map { objectKind in
                    ExportOutlineNode(
                        kind: .group(databaseID: database.id, objectKind: objectKind),
                        children: database.objects(ofKind: objectKind).map {
                            ExportOutlineNode(kind: .object(databaseID: database.id, objectID: $0.id))
                        }
                    )
                }
            )
        }
    }

    /// What a rebuild has to happen for. A checkbox toggle changes neither, so the tree is left
    /// alone and only the affected rows are redrawn.
    internal static func shapeFingerprint(of databases: [ExportDatabaseItem]) -> String {
        databases.map { database in
            let objects = database.objects.map { "\($0.kind.rawValue):\($0.id.uuidString)" }.joined(separator: ",")
            return "\(database.id.uuidString)[\(objects)]"
        }
        .joined(separator: "|")
    }
}
