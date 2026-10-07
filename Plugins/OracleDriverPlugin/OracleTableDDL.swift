//
//  OracleTableDDL.swift
//  OracleDriverPlugin
//

import Foundation
import TableProPluginKit

/// The `CREATE TABLE` the Structure DDL view shows and a SQL export replays, built from the catalog's columns.
///
/// `DBMS_METADATA.GET_DDL` is not used: on the wrong object type it raises ORA-31603, which leaves oracle-nio's
/// connection state machine broken.
///
/// Each column is written in the order Oracle's grammar takes it, measured on 23ai: the type verbatim, then
/// `GENERATED ALWAYS AS (...) VIRTUAL` or `DEFAULT`, then `NOT NULL`. `NOT NULL` before `DEFAULT` fails with
/// ORA-03076, and a type folded to upper case names no type at all when it is a quoted mixed-case object type.
internal enum OracleTableDDL {
    static func createTable(
        qualifiedTable: String,
        columns: [PluginColumnInfo],
        quote: (String) -> String
    ) -> String {
        let definitions = columns.map { "    " + columnDefinition($0, quote: quote) }
        return "CREATE TABLE \(qualifiedTable) (\n" + definitions.joined(separator: ",\n") + "\n);"
    }

    static func columnDefinition(_ column: PluginColumnInfo, quote: (String) -> String) -> String {
        var parts = [quote(column.name), column.ddlSpelling ?? column.dataType]
        if let clause = valueClause(for: column) {
            parts.append(clause)
        }
        if !column.isNullable {
            parts.append("NOT NULL")
        }
        return parts.joined(separator: " ")
    }

    /// An identity column gets no clause: a restore inserts the dump's rows with their keys, which a
    /// `GENERATED ALWAYS` identity refuses with ORA-32795.
    private static func valueClause(for column: PluginColumnInfo) -> String? {
        guard column.identityKind == nil else { return nil }
        if column.generationKind == .virtual || column.isGenerated,
           let expression = column.ddlGenerationExpression ?? column.generationExpression {
            return "GENERATED ALWAYS AS (\(expression)) VIRTUAL"
        }
        guard let defaultValue = column.ddlDefault ?? column.defaultValue, !defaultValue.isEmpty else { return nil }
        return "DEFAULT \(defaultValue)"
    }
}
