//
//  OracleIndexStatements.swift
//  OracleDriverPlugin
//

import Foundation
import TableProOracleCore
import TableProSQLQuoting

// The indexes an Oracle dump recreates after the rows, and the `CREATE INDEX` that recreates each. An index an enabled
// PRIMARY KEY or UNIQUE constraint owns is left out: `fetchTableDDL` writes the constraint, which makes its own index,
// and a second index on the same columns fails with ORA-01408. A disabled or NOVALIDATE constraint is written disabled
// and makes none, so an index it kept is written, and a NOVALIDATE one is enabled on it after the rows.
internal enum OracleIndexStatements {
    // NORMAL and BITMAP only: a function-based index keeps its key in a LONG column OracleNIO cannot decode. A
    // constraint row with no `INDEX_OWNER` is read as naming an index of its own schema.
    internal static func query(schema: String, table: String) -> String {
        """
            SELECT i.INDEX_NAME, i.UNIQUENESS, i.INDEX_TYPE, ic.COLUMN_NAME, ic.DESCEND
            FROM \(OracleDictionary.allIndexes) i
            JOIN \(OracleDictionary.allIndColumns) ic ON i.INDEX_NAME = ic.INDEX_NAME AND i.OWNER = ic.INDEX_OWNER
            WHERE i.TABLE_NAME = \(SQLQuoting.stringLiteral(table))
              AND i.OWNER = \(SQLQuoting.stringLiteral(schema))
              AND i.INDEX_TYPE IN ('NORMAL', 'BITMAP')
              AND NOT EXISTS (
                  SELECT 1 FROM \(OracleDictionary.allConstraints) c
                  WHERE c.CONSTRAINT_TYPE IN ('P', 'U')
                    AND c.STATUS = 'ENABLED'
                    AND c.VALIDATED = 'VALIDATED'
                    AND c.INDEX_NAME = i.INDEX_NAME
                    AND NVL(c.INDEX_OWNER, c.OWNER) = i.OWNER
              )
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
