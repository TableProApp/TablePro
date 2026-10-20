import Foundation
import TableProDatabase
import TableProModels

nonisolated struct RowLocator: Sendable {
    let row: [String?]
    let keyValues: [(column: String, value: String)]?

    static func identity(of driver: (any DatabaseDriver)?) -> RowIdentity {
        (driver as? any DriverRowWriting)?.rowIdentity ?? .keyColumns
    }

    static func canLocate(identity: RowIdentity, columns: [ColumnInfo], columnDetails: [ColumnInfo]) -> Bool {
        switch identity {
        case .keyColumns: columnDetails.contains(where: \.isPrimaryKey)
        case .everyColumn: !columns.isEmpty
        }
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
            guard !columns.isEmpty, cells.count == columns.count else { return nil }
            let isExact = cells.allSatisfy { cell in
                switch cell {
                case .null, .text: true
                case .truncatedText, .binary: false
                }
            }
            return isExact ? RowLocator(row: row, keyValues: nil) : nil
        }
    }
}
