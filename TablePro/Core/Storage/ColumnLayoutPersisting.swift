//
//  ColumnLayoutPersisting.swift
//  TablePro
//

import Foundation

struct ColumnLayoutTableKey: Hashable {
    let connectionId: UUID
    let databaseName: String
    let schemaName: String?
    let tableName: String

    var storageKey: String {
        CompositeStorageKey.make(
            connectionId: connectionId,
            databaseName: databaseName,
            schemaName: schemaName,
            tableName: tableName
        )
    }
}

@MainActor
protocol ColumnLayoutPersisting: AnyObject {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState?
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey)
    func clear(for key: ColumnLayoutTableKey)
    func loadHiddenColumns(for key: ColumnLayoutTableKey) -> Set<String>
    func saveHiddenColumns(_ hidden: Set<String>, for key: ColumnLayoutTableKey)
}

extension ColumnLayoutPersisting {
    func loadHiddenColumns(for key: ColumnLayoutTableKey) -> Set<String> { [] }
    func saveHiddenColumns(_ hidden: Set<String>, for key: ColumnLayoutTableKey) {}
}
