//
//  OracleColumnStatements.swift
//  OracleDriverPlugin
//

import Foundation
import TableProPluginKit

/// The `ALTER TABLE` that turns one column into another.
///
/// `MODIFY` names only what changed, because Oracle leaves every omitted attribute as it was and restating an unchanged
/// one is not neutral. Measured on 23ai: restating `NOT NULL` on a column that already has it fails the whole
/// statement with ORA-01442, so a default could never be changed on a `NOT NULL` column; restating the type writes the
/// type the grid displays, which is built from the byte length, so `VARCHAR2(20 CHAR)` became `VARCHAR2(80)` in bytes
/// on an edit that only touched nullability; and restating `NULL` next to a `DEFAULT ON NULL` fails with ORA-30665.
internal enum OracleColumnStatements {
    internal static func modify(
        qualifiedTable: String,
        oldColumn: PluginColumnDefinition,
        newColumn: PluginColumnDefinition,
        quote: (String) -> String
    ) -> String? {
        var statements: [String] = []
        if oldColumn.name != newColumn.name {
            statements.append(
                "ALTER TABLE \(qualifiedTable) RENAME COLUMN \(quote(oldColumn.name)) TO \(quote(newColumn.name))"
            )
        }
        if let change = attributeChange(from: oldColumn, to: newColumn, quote: quote) {
            statements.append("ALTER TABLE \(qualifiedTable) MODIFY (\(change))")
        }
        return statements.isEmpty ? nil : statements.joined(separator: ";\n")
    }

    /// No default is written as `DEFAULT NULL`, because Oracle has no way to take a default away: the dictionary then
    /// reports the text `NULL`, which reads back as the `NULL` default.
    private static func attributeChange(
        from oldColumn: PluginColumnDefinition,
        to newColumn: PluginColumnDefinition,
        quote: (String) -> String
    ) -> String? {
        let typeChanged = oldColumn.dataType.uppercased() != newColumn.dataType.uppercased()
        let nullabilityChanged = oldColumn.isNullable != newColumn.isNullable
        let defaultChanged = oldColumn.defaultValue != newColumn.defaultValue
        guard typeChanged || nullabilityChanged || defaultChanged else { return nil }

        var parts = [quote(newColumn.name)]
        if typeChanged {
            parts.append(newColumn.dataType.uppercased())
        }
        if defaultChanged {
            parts.append("DEFAULT \(newColumn.defaultValue ?? "NULL")")
        }
        if nullabilityChanged {
            parts.append(newColumn.isNullable ? "NULL" : "NOT NULL")
        }
        return parts.joined(separator: " ")
    }
}
