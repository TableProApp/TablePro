import Foundation

extension NewTableImportPlanner.Table {
    init(_ scope: TableScope) {
        self.init(connectionId: scope.connectionId, database: scope.database, schema: scope.schema, name: scope.table)
    }
}

extension NewTableImportPlanner {
    func plan(forTable table: TableScope, createTableSQL: String) -> NewTableImportPlan {
        plan(for: NewTableImportPlanner.Table(table), createTableSQL: createTableSQL)
    }

    func created(_ table: TableScope) -> Bool {
        created(NewTableImportPlanner.Table(table))
    }

    func createdTableNames(in scope: DatabaseScope) -> [String] {
        createdTableNames(connectionId: scope.connectionId, database: scope.database, schema: scope.schema)
    }

    mutating func recordCreated(_ table: TableScope, createTableSQL: String) {
        recordCreated(NewTableImportPlanner.Table(table), createTableSQL: createTableSQL)
    }
}
