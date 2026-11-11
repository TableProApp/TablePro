import Foundation
import TableProModels

// The key a browsed row's long values are read back by: the table's key columns found in the result, valued from the
// row as the driver read it, so a key cut for display still carries its whole text.
nonisolated struct LazyCellKey: Sendable {
    private struct KeyColumn: Sendable {
        let name: String
        let index: Int
    }

    private let table: String
    private let keyColumns: [KeyColumn]

    // Nil without a key, or when the result leaves out one of its columns.
    init?(_ context: LazyContext?, columnNames: [String]) {
        guard let context, !context.primaryKeyColumns.isEmpty else { return nil }
        var keyColumns: [KeyColumn] = []
        for name in context.primaryKeyColumns {
            guard let index = columnNames.firstIndex(of: name) else { return nil }
            keyColumns.append(KeyColumn(name: name, index: index))
        }
        table = context.table
        self.keyColumns = keyColumns
    }

    // Nil when a key value is NULL or not text, which no key predicate matches.
    func primaryKey(_ value: (Int) -> String?) -> [PrimaryKeyComponent]? {
        var components: [PrimaryKeyComponent] = []
        components.reserveCapacity(keyColumns.count)
        for key in keyColumns {
            guard let text = value(key.index) else { return nil }
            components.append(PrimaryKeyComponent(column: key.name, value: text))
        }
        return components
    }

    func ref(column: String, primaryKey: [PrimaryKeyComponent]?) -> CellRef? {
        primaryKey.map { CellRef(table: table, column: column, primaryKey: $0) }
    }
}
