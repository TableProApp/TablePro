//
//  DatabaseTreeOutlineCoordinator+FolderNodes.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The folders a container shows and the objects filed in them.
///
/// A folder holds tables and views of one database or schema. The flat list puts its folders in a
/// Folders section of their own, above the kind sections; a tree container lists them first among
/// its children. Either way an object sits in one row only, so a filed table is drawn inside its
/// folder and left out of its kind section.
extension DatabaseTreeOutlineCoordinator {
    internal static let tableKinds = SidebarObjectKind.allCases.filter { $0.category == .table }

    internal func folderScope(for container: TableFolderContainer) -> DatabaseScope? {
        switch container {
        case .browsed:
            return CatalogEditAdoption().containerScope(
                database: browsingDatabase, schema: activeSchema, connectionId: connectionId
            )
        case .container(let database, let schema):
            return CatalogEditAdoption().containerScope(database: database, schema: schema, connectionId: connectionId)
        case .scope(let scope):
            return scope
        }
    }

    internal func folderScope(of ref: DatabaseTreeTableRef) -> DatabaseScope? {
        CatalogEditAdoption().objectScope(for: ref, connectionId: connectionId)
    }

    // MARK: - Plans

    /// The flat list shows folders only while the catalog it lists belongs to the scope it is
    /// browsing. During a database switch the list still holds the previous database's tables, and
    /// pairing them with the next one's folders would file a table of one into a folder of the other,
    /// so for that moment the tables are listed without folders.
    internal func flatPlan() -> TableFolderPlan {
        if let flatFolderPlan { return flatFolderPlan }
        guard let viewModel else { return .empty }
        let tables = schemaService.tables(for: connectionId)
        let objectsByKind = Dictionary(uniqueKeysWithValues: Self.tableKinds.map {
            ($0, viewModel.filteredTables(of: $0, from: tables))
        })
        let scope = folderScope(for: .browsed)
        let listsBrowsedCatalog = schemaService.loadedScope(for: connectionId).map { loaded in
            CatalogEditAdoption().containerScope(
                database: loaded.database, schema: loaded.schema, connectionId: connectionId
            ) == scope
        } ?? true
        let plan = makePlan(objectsByKind: objectsByKind, scope: listsBrowsedCatalog ? scope : nil)
        flatFolderPlan = plan
        return plan
    }

    internal func containerPlan(
        database: String,
        schema: String?,
        buckets: DatabaseTreeObjectBuckets
    ) -> TableFolderPlan {
        let key = DatabaseTreeContainerKey(database: database, schema: schema, searchText: searchText)
        if let cached = containerFolderPlans[key] { return cached }
        let objectsByKind = Dictionary(uniqueKeysWithValues: Self.tableKinds.map { ($0, buckets.tables[$0] ?? []) })
        let scope = folderScope(for: .container(database: database.nilIfEmpty, schema: schema))
        let plan = makePlan(objectsByKind: objectsByKind, scope: scope)
        containerFolderPlans[key] = plan
        return plan
    }

    private func makePlan(objectsByKind: [SidebarObjectKind: [TableInfo]], scope: DatabaseScope?) -> TableFolderPlan {
        TableFolderPlanner.plan(
            objectsByKind: objectsByKind,
            layout: scope.map { tableFolderStorage.layout(in: $0) } ?? .empty,
            searching: !searchText.isEmpty,
            keeping: revealedFolderId.map { [$0] } ?? []
        )
    }

    /// The counts a container's kind groups are shown for: what is left in each once the filed
    /// objects have moved into their folders. A kind whose objects are all filed keeps its group,
    /// empty and without a "No tables" row, because it is where a drag takes an object back out.
    internal func looseItemCounts(
        _ counts: [SidebarObjectKind: Int],
        plan: TableFolderPlan
    ) -> [SidebarObjectKind: Int] {
        var loose = counts
        for kind in Self.tableKinds {
            loose[kind] = plan.looseCount(of: kind)
        }
        return loose
    }

    // MARK: - Nodes

    internal func flatFoldersSectionNodes() -> [DatabaseTreeNode] {
        guard !flatPlan().entries.isEmpty else { return [] }
        return [node(id: DatabaseTreeNode.foldersSectionId, kind: .foldersSection)]
    }

    internal func flatFolderNodes() -> [DatabaseTreeNode] {
        let database = browsingDatabase
        return folderNodes(flatPlan()) { table in
            DatabaseTreeTableRef(database: database, schema: table.schema, table: table)
        }
    }

    internal func containerFolderNodes(_ plan: TableFolderPlan, database: String, schema: String?) -> [DatabaseTreeNode] {
        let rowDatabase = database.nilIfEmpty
        return folderNodes(plan) { table in
            DatabaseTreeTableRef(database: rowDatabase, schema: schema, table: table)
        }
    }

    /// Each member row is spelled the way its section would spell it, so a filed table is the same
    /// row, with the same id and the same menus, as the one it replaces in its section.
    private func folderNodes(
        _ plan: TableFolderPlan,
        memberRef: (TableInfo) -> DatabaseTreeTableRef
    ) -> [DatabaseTreeNode] {
        plan.entries.map { entry in
            let ref = DatabaseTreeFolderRef(folder: entry.folder, members: entry.members.map(memberRef))
            return node(id: DatabaseTreeNode.tableFolderId(entry.folder.id), kind: .tableFolder(ref))
        }
    }

    /// An empty folder says so, the way an empty container does, rather than opening on nothing.
    internal func folderMemberNodes(of ref: DatabaseTreeFolderRef) -> [DatabaseTreeNode] {
        guard !ref.members.isEmpty else {
            guard searchText.isEmpty else { return [] }
            let parentId = DatabaseTreeNode.tableFolderId(ref.folder.id)
            return [node(id: DatabaseTreeNode.statusId(parentId: parentId, status: .empty), kind: .status(.empty))]
        }
        return ref.members.map { node(id: DatabaseTreeNode.tableId($0), kind: .table($0)) }
    }
}
