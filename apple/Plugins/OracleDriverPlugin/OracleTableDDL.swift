//
//  OracleTableDDL.swift
//  OracleDriverPlugin
//

import Foundation
import TableProOracleCore
import TableProPluginKit
import TableProSQLGrammar

/// The `CREATE TABLE` and `CREATE VIEW` the Structure DDL view shows and a SQL export replays, built from the catalog.
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
    ) throws -> String {
        let definitions = try columns.map { "    " + (try columnDefinition($0, quote: quote)) }
        return "CREATE TABLE \(qualifiedTable) (\n" + definitions.joined(separator: ",\n") + "\n);"
    }

    /// `TEXT_VC` is the view's query alone, so its column names go in the header: a view declared
    /// `v (public_id) AS SELECT internal_id ...` replayed without them exposes `INTERNAL_ID`, and one
    /// over an unaliased expression cannot be recreated at all. `DBMS_METADATA` writes the list too.
    static func createView(qualifiedView: String, columns: [String], query: String, quote: (String) -> String) -> String {
        let columnList = columns.isEmpty ? "" : " (" + columns.map(quote).joined(separator: ", ") + ")"
        return "CREATE OR REPLACE VIEW \(qualifiedView)\(columnList) AS\n\(query)"
    }

    static func columnDefinition(_ column: PluginColumnInfo, quote: (String) -> String) throws -> String {
        var parts = [quote(column.name), column.ddlSpelling ?? column.dataType]
        if let clause = try valueClause(for: column) {
            parts.append(clause)
        }
        if !column.isNullable {
            parts.append("NOT NULL")
        }
        return parts.joined(separator: " ")
    }

    // An identity column gets no clause: a restore inserts the dump's rows with their keys, which a
    // `GENERATED ALWAYS` identity refuses with ORA-32795. Catalog text goes in only as one expression.
    private static func valueClause(for column: PluginColumnInfo) throws -> String? {
        guard column.identityKind == nil else { return nil }
        if column.generationKind == .virtual || column.isGenerated,
           let expression = column.ddlGenerationExpression ?? column.generationExpression {
            guard isSingleExpression(expression) else {
                throw refusal(String(localized: "The expression of generated column %@ cannot be written as SQL."), column)
            }
            return "GENERATED ALWAYS AS (\(expression)) VIRTUAL"
        }
        guard let stored = column.ddlDefault ?? column.defaultValue else { return nil }
        let defaultValue = SQLExpressionFragment.strippingComments(stored, databaseTypeId: "Oracle")
        guard !defaultValue.isEmpty else { return nil }
        guard isSingleExpression(defaultValue) else {
            throw refusal(String(localized: "The default of column %@ cannot be written as SQL."), column)
        }
        return "DEFAULT \(defaultValue)"
    }

    private static func isSingleExpression(_ text: String) -> Bool {
        SQLExpressionFragment.isSingleExpression(text, databaseTypeId: "Oracle")
    }

    private static func refusal(_ format: String, _ column: PluginColumnInfo) -> OraclePluginError {
        OraclePluginError(core: .queryFailed(String(format: format, column.name)))
    }
}
