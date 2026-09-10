//
//  ObjectCopyServerSideInsert.swift
//  TablePro
//
//  The copy that never leaves the server.
//
//  Streaming a table through the app costs a read, a decode, a re-encode and a
//  write per row, and every one of those bytes crosses the network twice. When
//  both sides of a copy are the same connection, the server can do the whole
//  thing itself with one `INSERT INTO … SELECT`, which is the difference
//  between minutes and seconds on a large table.
//
//  Two things are given up for that, and both are why this is not the only path.
//  There is no per-row progress, because the statement reports nothing until it
//  finishes; and Stop cannot land inside it, because a statement already sent is
//  the server's to finish. The plan says so and the review shows the statement
//  itself, so neither is a surprise.
//
//  The gate is narrow on purpose. Naming the other side of a copy needs a
//  reference the engine resolves the same way from where the statement runs, and
//  the engines disagree about whether one database can name another at all:
//  MySQL and ClickHouse write `db.table`, SQL Server writes `db.schema.table`,
//  and PostgreSQL cannot do it in a single statement under any spelling. Getting
//  that wrong does not corrupt anything, because the statement is rejected
//  rather than resolved to the wrong table, but a copy that fails at its last
//  step is worse than one that took the slow path.
//

import Foundation
import TableProPluginKit

internal enum ObjectCopyServerSideInsert {
    /// Whether the server can be asked to copy between these two on its own.
    ///
    /// One connection, so one session and one transaction, and the same engine follows from that.
    /// Beyond that it is only a question of whether the target's scope can name the source's.
    internal static func isEligible(source: DatabaseEndpoint, target: DatabaseEndpoint) -> Bool {
        guard source.connectionId == target.connectionId else { return false }
        guard !crossesDatabases(SQLTypeFamily.of(target.databaseType)) else { return true }
        return source.database == target.database
    }

    internal static func statement(
        _ input: Input,
        driver: any PluginDatabaseDriver
    ) -> String? {
        guard !input.sourceColumns.isEmpty,
              input.sourceColumns.count == input.targetColumns.count else { return nil }
        guard let from = reference(
            database: input.source.database,
            schema: input.sourceSchema,
            table: input.sourceTable,
            family: SQLTypeFamily.of(input.target.databaseType),
            driver: driver
        ) else { return nil }

        let into = ObjectCopySelectQuery.qualified(input.targetTable, input.targetSchema, driver)
        let targetList = input.targetColumns.map { driver.quoteIdentifier($0) }.joined(separator: ", ")
        let sourceList = input.sourceColumns.map { driver.quoteIdentifier($0) }.joined(separator: ", ")
        var select = "SELECT \(sourceList) FROM \(from)"
        if let filter = input.scope?.sanitizedFilter, !filter.isEmpty {
            select += " WHERE \(filter)"
        }
        if let rowLimit = input.scope?.rowLimit {
            select = driver.injectRowLimit(select, limit: rowLimit) ?? "\(select) LIMIT \(rowLimit)"
        }
        return "INSERT INTO \(into) (\(targetList)) \(select);"
    }

    internal struct Input: Sendable {
        internal let source: DatabaseEndpoint
        internal let target: DatabaseEndpoint
        internal let sourceTable: String
        internal let sourceSchema: String?
        internal let targetTable: String
        internal let targetSchema: String?
        internal let sourceColumns: [String]
        internal let targetColumns: [String]
        internal let scope: PluginExportRowScope?
    }

    // MARK: - Naming the other side

    /// Spelled as the engine spells it, and only where the engine has a spelling.
    ///
    /// An engine that can name a second database is given the fully qualified name even when the
    /// two sides share one, because it is unambiguous either way and comparing the two database
    /// strings is not. `Shop` and `shop` are one database on a case-insensitive MySQL server and
    /// two on a case-sensitive one; treating them as one and dropping the qualifier would resolve
    /// the SELECT against the database the statement runs in, which is the target's, so the copy
    /// would read the table it was about to write.
    ///
    /// The others get the ordinary qualified name and are only reached when the databases match
    /// exactly. PostgreSQL has no spelling at all: a second database needs `dblink` or a foreign
    /// data wrapper, neither of which a copy may install on the user's server.
    private static func reference(
        database: String,
        schema: String?,
        table: String,
        family: SQLTypeFamily,
        driver: any PluginDatabaseDriver
    ) -> String? {
        guard crossesDatabases(family), !database.isEmpty else {
            return ObjectCopySelectQuery.qualified(table, schema, driver)
        }
        switch family {
        case .mysql, .clickhouse:
            return "\(driver.quoteIdentifier(database)).\(driver.quoteIdentifier(table))"
        case .mssql:
            let resolved = schema?.nilIfEmpty ?? "dbo"
            return "\(driver.quoteIdentifier(database)).\(driver.quoteIdentifier(resolved))"
                + ".\(driver.quoteIdentifier(table))"
        case .postgres, .sqlite, .oracle, .duckdb, .generic:
            return nil
        }
    }

    private static func crossesDatabases(_ family: SQLTypeFamily) -> Bool {
        switch family {
        case .mysql, .clickhouse, .mssql: return true
        case .postgres, .sqlite, .oracle, .duckdb, .generic: return false
        }
    }
}
