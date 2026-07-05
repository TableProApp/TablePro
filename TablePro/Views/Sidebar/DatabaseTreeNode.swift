//
//  DatabaseTreeNode.swift
//  TablePro
//

import Foundation
import TableProPluginKit

final class DatabaseTreeNode {
    enum Status: Equatable {
        case loading
        case empty
        case error(String)
    }

    enum Kind {
        case database(DatabaseMetadata)
        case schema(database: String, schema: String)
        case table(DatabaseTreeTableRef)
        case routine(DatabaseTreeRoutineRef)
        case status(Status)
    }

    let id: String
    var kind: Kind

    init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    var isExpandable: Bool {
        switch kind {
        case .database, .schema: return true
        case .table, .routine, .status: return false
        }
    }

    var tableRef: DatabaseTreeTableRef? {
        if case .table(let ref) = kind { return ref }
        return nil
    }

    static func databaseId(_ database: String) -> String { "db\u{1}\(database)" }
    static func schemaId(database: String, schema: String) -> String { "schema\u{1}\(database)\u{1}\(schema)" }
    static func tableId(_ ref: DatabaseTreeTableRef) -> String { "table\u{1}\(ref.id)" }
    static func routineId(_ ref: DatabaseTreeRoutineRef) -> String { "routine\u{1}\(ref.id)" }
    static func statusId(parentId: String, status: Status) -> String {
        switch status {
        case .loading: return "\(parentId)\u{1}status.loading"
        case .empty: return "\(parentId)\u{1}status.empty"
        case .error: return "\(parentId)\u{1}status.error"
        }
    }
}
