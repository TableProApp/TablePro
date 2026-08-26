//
//  SnowflakeStatementType.swift
//  SnowflakeDriverPlugin
//
//  What the server said the statement was, rather than what its result looks like. The response
//  carries `statementTypeId`, so the row count never has to be guessed from a column name: a DML
//  statement reports its counts and everything else reports none, whatever its columns are called.
//

import Foundation

enum SnowflakeStatementType {
    static let select = 0x1000
    static let dml = 0x3000
    static let multiTableInsert = 0x3500
    static let multiStatement = 0xA000

    static func isDML(_ identifier: Int) -> Bool {
        (dml ... multiTableInsert).contains(identifier)
    }

    /// A DML result is one row of counts, and how many columns it has depends on the statement:
    /// `INSERT` and `DELETE` report one, `UPDATE` reports rows updated and multi-joined rows
    /// updated, and a multi-clause `MERGE` reports one per clause. The answer is their sum, so
    /// reading only the first column loses every count after it.
    static func affectedRows(statementTypeId: Int, row: [PluginCellValueBox]?) -> Int {
        guard isDML(statementTypeId), let row, !row.isEmpty else { return 0 }
        var total = 0
        for cell in row {
            guard case .text(let value) = cell, let count = Int(value) else { return 0 }
            total += count
        }
        return total
    }
}
