//
//  DatabaseTreeOutlineCoordinator+TableDetails.swift
//  TablePro
//

import Foundation

/// The rows under a table while Table Details is on: one group per kind of detail, and under each
/// group the list its engine read for that table.
extension DatabaseTreeOutlineCoordinator {
    /// What a table lists follows its relation type and what its engine can read.
    internal func tableDetailGroupNodes(of ref: DatabaseTreeTableRef) -> [DatabaseTreeNode] {
        TableDetailGroupResolver.groups(
            for: ref.table.type,
            capabilities: TableDetailCapabilities(databaseType: databaseType),
            showsPartitions: showsPartitions
        )
        .map { kind in
            let group = DatabaseTreeTableDetailGroupRef(table: ref, kind: kind)
            return node(id: DatabaseTreeNode.tableDetailGroupId(group), kind: .tableDetailGroup(group))
        }
    }

    internal func tableDetailNodes(in group: DatabaseTreeTableDetailGroupRef) -> [DatabaseTreeNode] {
        let groupId = DatabaseTreeNode.tableDetailGroupId(group)
        let ref = group.table
        guard let kind = group.kind.detailKind else {
            return partitionNodes(of: ref, parentId: groupId)
        }
        switch tableDetailsLoadState(ref, kind: kind) {
        case .idle, .loading:
            return [statusNode(parentId: groupId, status: .loading)]
        case .failed(let message):
            return [statusNode(parentId: groupId, status: .error(message))]
        case .loaded(let list):
            let entries = TableDetailRows.entries(for: list, table: ref)
            guard !entries.isEmpty else { return [statusNode(parentId: groupId, status: .empty)] }
            return entries.map { entry in
                let id = DatabaseTreeNode.tableDetailId(groupId: groupId, key: entry.key)
                switch entry.row {
                case .detail(let detail): return node(id: id, kind: .tableDetail(detail))
                case .trigger(let trigger): return node(id: id, kind: .trigger(trigger))
                }
            }
        }
    }

    /// Nil until the group's list has loaded, so the row shows no number rather than a zero it does not know.
    internal func tableDetailCount(_ group: DatabaseTreeTableDetailGroupRef) -> Int? {
        let ref = group.table
        guard let kind = group.kind.detailKind else {
            return service.partitionsLoadState(
                connectionId: connectionId, database: ref.database ?? "", schema: ref.schema, table: ref.table.name
            )
            .value?
            .filter { $0.parentPartitionName == nil }
            .count
        }
        return tableDetailsLoadState(ref, kind: kind).value?.count
    }

    private func tableDetailsLoadState(
        _ ref: DatabaseTreeTableRef, kind: TableDetailKind
    ) -> MetadataLoadState<TableDetailList> {
        service.tableDetailsLoadState(
            connectionId: connectionId, database: ref.database ?? "", schema: ref.schema, table: ref.table.name, kind: kind
        )
    }
}
