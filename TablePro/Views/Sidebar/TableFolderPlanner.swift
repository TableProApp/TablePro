//
//  TableFolderPlanner.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// A folder as the outline draws it: the folder, plus the rows it holds. The rows are part of the
/// identity so a folder repaints when what it holds changes.
internal struct DatabaseTreeFolderRef: Hashable, Sendable {
    internal let folder: TableFolder
    internal let members: [DatabaseTreeTableRef]

    internal var memberCount: Int { members.count }
}

/// Where a New Folder command puts the folder: the database and schema the flat list is browsing,
/// a container the tree names, or the scope of the folder the command was raised on. The first two
/// resolve to a scope only when the command runs, because resolving needs the session and the menu
/// spec that emits them is pure.
internal enum TableFolderContainer: Hashable, Sendable {
    case browsed
    case container(database: String?, schema: String?)
    case scope(DatabaseScope)
}

/// The rows one container shows once its folders are applied.
internal struct TableFolderPlan: Equatable {
    internal struct Entry: Equatable {
        internal let folder: TableFolder
        internal let members: [TableInfo]
    }

    internal let entries: [Entry]
    internal let looseByKind: [SidebarObjectKind: [TableInfo]]
    internal let filedKinds: Set<SidebarObjectKind>

    internal static let empty = TableFolderPlan(entries: [], looseByKind: [:], filedKinds: [])

    internal func looseObjects(of kind: SidebarObjectKind) -> [TableInfo] {
        looseByKind[kind] ?? []
    }

    internal func looseCount(of kind: SidebarObjectKind) -> Int {
        looseObjects(of: kind).count
    }

    /// Whether some object of this kind is out of its section because it sits in a folder. A section
    /// left empty that way is not one with nothing in it, so it must not say "No tables".
    internal func hasFiledObjects(of kind: SidebarObjectKind) -> Bool {
        filedKinds.contains(kind)
    }
}

/// Sorts a container's tables and views into its folders.
///
/// Objects keep the order they arrive in, so the sections read as they always did. A folder's
/// members are sorted by name, because a folder mixes kinds and the only order that holds across
/// them is the name. While a search is running a folder with no match is left out, except the ones
/// named in `keeping`, which is the folder being named: dropping its row would end the edit.
internal enum TableFolderPlanner {
    internal static func plan(
        objectsByKind: [SidebarObjectKind: [TableInfo]],
        layout: TableFolderLayout,
        searching: Bool,
        keeping kept: Set<UUID> = []
    ) -> TableFolderPlan {
        guard !layout.isEmpty else {
            return TableFolderPlan(entries: [], looseByKind: objectsByKind, filedKinds: [])
        }
        var members: [UUID: [TableInfo]] = [:]
        var looseByKind: [SidebarObjectKind: [TableInfo]] = [:]
        var filedKinds: Set<SidebarObjectKind> = []
        for (kind, objects) in objectsByKind {
            var loose: [TableInfo] = []
            for object in objects {
                guard let folderId = layout.placements[object.name] else {
                    loose.append(object)
                    continue
                }
                members[folderId, default: []].append(object)
                filedKinds.insert(kind)
            }
            looseByKind[kind] = loose
        }
        let entries = layout.folders.compactMap { folder -> TableFolderPlan.Entry? in
            let filed = (members[folder.id] ?? []).sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            if searching, filed.isEmpty, !kept.contains(folder.id) { return nil }
            return TableFolderPlan.Entry(folder: folder, members: filed)
        }
        return TableFolderPlan(entries: entries, looseByKind: looseByKind, filedKinds: filedKinds)
    }
}
