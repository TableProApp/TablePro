//
//  PostgreSQLIndexClauses.swift
//  PostgreSQLDriverPlugin
//
//  What a `CREATE INDEX` writes after the table and in its `WHERE` clause. Pure, so the choice
//  between the server's own spelling and the one rebuilt from the fields is pinned by a test
//  without loading the driver.
//

import Foundation
import TableProPluginKit

enum PostgreSQLIndexClauses {
    static func createStatement(for index: PluginIndexDefinition, qualifiedTable: String) -> String {
        let unique = index.isUnique ? "UNIQUE " : ""
        let name = PostgreSQLObjectQueries.quoteIdentifier(index.name)
        var statement = "CREATE \(unique)INDEX \(name) ON \(qualifiedTable) \(methodAndKeys(for: index))"
        if let predicate = whereClause(for: index) {
            statement += " WHERE \(predicate)"
        }
        return statement
    }

    /// `ddlMethodAndKeys` first, because it is the only spelling that keeps an operator class, a
    /// collation, a sort order, `NULLS NOT DISTINCT` and a storage parameter, and that names an
    /// extension's operator class with its schema.
    ///
    /// The fields are the fallback for an index the structure editor changed. An expression is
    /// parenthesised rather than quoted, which the grammar accepts for any expression, and quoting it
    /// named a column that does not exist.
    static func methodAndKeys(for index: PluginIndexDefinition) -> String {
        if let spelling = index.ddlMethodAndKeys?.nilIfEmpty {
            return spelling
        }
        let expressions = Set(index.expressions ?? [])
        let keys = index.columns
            .map { expressions.contains($0) ? "(\($0))" : PostgreSQLObjectQueries.quoteIdentifier($0) }
            .joined(separator: ", ")
        var clause = method(for: index).map { "USING \($0) " } ?? ""
        clause += "(\(keys))"
        if let included = index.includedColumns, !included.isEmpty {
            let columns = included.map(PostgreSQLObjectQueries.quoteIdentifier).joined(separator: ", ")
            clause += " INCLUDE (\(columns))"
        }
        return clause
    }

    static func whereClause(for index: PluginIndexDefinition) -> String? {
        index.ddlWhereClause?.nilIfEmpty ?? index.whereClause?.nilIfEmpty
    }

    private static func method(for index: PluginIndexDefinition) -> String? {
        guard let type = index.indexType?.uppercased(),
              PostgreSQLVersionedStatements.postgreSQLIndexMethods.contains(type) else { return nil }
        return type.lowercased()
    }
}
