//
//  OracleIndexStatements.swift
//  OracleDriverPlugin
//

import Foundation

/// The indexes an Oracle dump has to recreate, and the `CREATE INDEX` that recreates them.
///
/// Every index is taken, constraint-backed ones included, because this driver's `fetchTableDDL`
/// writes column definitions and nothing else: no primary key, no unique constraint. Excluding
/// them would have left an Oracle dump with no uniqueness anywhere, so a restore would accept
/// duplicate rows the source rejected.
internal enum OracleIndexStatements {
    /// `INDEX_TYPE` is restricted to `NORMAL` and `BITMAP`. A function-based index keeps its key in
    /// `ALL_IND_EXPRESSIONS.COLUMN_EXPRESSION`, whose datatype is `LONG`, the datatype this driver
    /// already avoids reading because OracleNIO cannot decode it. Such an index would come back
    /// carrying its `SYS_NC` shadow column instead of its expression, so it is left out of the dump
    /// rather than written wrong.
    internal static func query(schema: String, table: String) -> String {
        let owner = schema.replacingOccurrences(of: "'", with: "''")
        let tableName = table.replacingOccurrences(of: "'", with: "''")
        return """
            SELECT i.INDEX_NAME, i.UNIQUENESS, i.INDEX_TYPE, ic.COLUMN_NAME, ic.DESCEND
            FROM ALL_INDEXES i
            JOIN ALL_IND_COLUMNS ic ON i.INDEX_NAME = ic.INDEX_NAME AND i.OWNER = ic.INDEX_OWNER
            WHERE i.TABLE_NAME = '\(tableName)'
              AND i.OWNER = '\(owner)'
              AND i.INDEX_TYPE IN ('NORMAL', 'BITMAP')
            ORDER BY i.INDEX_NAME, ic.COLUMN_POSITION
            """
    }

    /// Each row is `INDEX_NAME, UNIQUENESS, INDEX_TYPE, COLUMN_NAME, DESCEND`. Statements come back
    /// in the order the rows arrive, one per index.
    internal static func render(
        rows: [[String?]],
        schema: String,
        table: String,
        quote: (String) -> String
    ) -> [String] {
        var order: [String] = []
        var columns: [String: [String]] = [:]
        var unique: [String: Bool] = [:]
        var bitmap: [String: Bool] = [:]

        for row in rows {
            guard let name = row.element(at: 0), let column = row.element(at: 3) else { continue }
            if columns[name] == nil {
                order.append(name)
                columns[name] = []
                unique[name] = row.element(at: 1)?.uppercased() == "UNIQUE"
                bitmap[name] = row.element(at: 2)?.uppercased() == "BITMAP"
            }
            let quoted = quote(column)
            let descending = row.element(at: 4)?.uppercased() == "DESC"
            columns[name]?.append(descending ? "\(quoted) DESC" : quoted)
        }

        return order.compactMap { name in
            guard let keyColumns = columns[name], !keyColumns.isEmpty else { return nil }
            var statement = "CREATE "
            if unique[name] == true {
                statement += "UNIQUE "
            } else if bitmap[name] == true {
                statement += "BITMAP "
            }
            statement += "INDEX \(quote(schema)).\(quote(name))"
            statement += " ON \(quote(schema)).\(quote(table))"
            return statement + " (\(keyColumns.joined(separator: ", ")));"
        }
    }
}

private extension Array where Element == String? {
    func element(at index: Int) -> String? {
        indices.contains(index) ? self[index] : nil
    }
}
