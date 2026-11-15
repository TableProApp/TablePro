import Foundation

nonisolated enum NewTableImportPlan: Equatable {
    case create
    case reuseAfterClearing
    case nameTakenWithDifferentColumns
}

// A failed import leaves its table behind, and a retry may neither create it again nor write the rows it kept a second
// time. So a table is reused, after clearing, only when this sheet made it with the same DDL. A table is known by its
// database and schema too: keyed by name alone, a retry cleared a same-named table in another database.
nonisolated struct NewTableImportPlanner {
    nonisolated struct Table: Hashable, Sendable {
        let connectionId: UUID
        let database: String?
        let schema: String?
        let name: String
    }

    private var createStatements: [Table: String] = [:]

    func plan(for table: Table, createTableSQL: String) -> NewTableImportPlan {
        guard let previousSQL = createStatements[table] else {
            return .create
        }
        return previousSQL == createTableSQL ? .reuseAfterClearing : .nameTakenWithDifferentColumns
    }

    func created(_ table: Table) -> Bool {
        createStatements[table] != nil
    }

    func createdTableNames(connectionId: UUID, database: String?, schema: String?) -> [String] {
        createStatements.keys
            .filter { $0.connectionId == connectionId && $0.database == database && $0.schema == schema }
            .map(\.name)
    }

    mutating func recordCreated(_ table: Table, createTableSQL: String) {
        createStatements[table] = createTableSQL
    }
}
