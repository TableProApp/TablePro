import Foundation
import TableProDatabase
import TableProModels

nonisolated struct RowLocator: Sendable {
    let row: [String?]
    let keyValues: [(column: String, value: String)]?
    // The columns `row` holds, when that is not every column read.
    var storedColumns: [String]?

    func columnNames(of columns: [ColumnInfo]) -> [String] {
        storedColumns ?? columns.map(\.name)
    }

    static func identity(of driver: (any DatabaseDriver)?) -> RowIdentity {
        (driver as? any DriverRowWriting)?.rowIdentity ?? .keyColumns
    }

    static func canLocate(identity: RowIdentity, columns: [ColumnInfo], columnDetails: [ColumnInfo]) -> Bool {
        switch identity {
        case .keyColumns:
            return columnDetails.contains(where: \.isPrimaryKey)
        case .everyColumn:
            let generated = generatedNames(columnDetails)
            return columns.contains { !generated.contains($0.name) }
        }
    }

    // A MATERIALIZED or ALIAS value changes with its sources, so a row is matched on what it stores.
    private static func generatedNames(_ columnDetails: [ColumnInfo]) -> Set<String> {
        Set(columnDetails.filter(\.isGenerated).map(\.name))
    }

    // A binary or cut-off cell holds placeholder text, which as a predicate matches no row, so such a row has no locator.
    static func locate(
        cells: [Cell],
        columns: [ColumnInfo],
        columnDetails: [ColumnInfo],
        identity: RowIdentity
    ) -> RowLocator? {
        let row = Row(cells: cells).legacyValues
        switch identity {
        case .keyColumns:
            let keyColumns = columnDetails.filter(\.isPrimaryKey)
            guard !keyColumns.isEmpty else { return nil }
            var values: [(column: String, value: String)] = []
            for key in keyColumns {
                guard let index = columns.firstIndex(where: { $0.name == key.name }),
                      index < cells.count,
                      let value = cells[index].keyText(column: key.name) else { return nil }
                values.append((column: key.name, value: value))
            }
            return RowLocator(row: row, keyValues: values)
        case .everyColumn:
            guard cells.count == columns.count else { return nil }
            let generated = generatedNames(columnDetails)
            let stored = columns.indices.filter { !generated.contains(columns[$0].name) }
            guard !stored.isEmpty else { return nil }
            let isExact = stored.allSatisfy { index in
                switch cells[index] {
                case .null, .text: true
                case .truncatedText, .binary: false
                }
            }
            guard isExact else { return nil }
            guard stored.count < columns.count else { return RowLocator(row: row, keyValues: nil) }
            return RowLocator(
                row: stored.map { row[$0] },
                keyValues: nil,
                storedColumns: stored.map { columns[$0].name }
            )
        }
    }
}
