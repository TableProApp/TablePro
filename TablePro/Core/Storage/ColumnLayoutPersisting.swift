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
        [connectionId.uuidString, databaseName, schemaName ?? "", tableName]
            .map { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0 }
            .joined(separator: ".")
    }
}

@MainActor
protocol ColumnLayoutPersisting: AnyObject {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState?
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey)
    func clear(for key: ColumnLayoutTableKey)
}
