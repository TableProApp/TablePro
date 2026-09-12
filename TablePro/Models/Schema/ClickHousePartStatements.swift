//
//  ClickHousePartStatements.swift
//  TablePro
//
//  The statements the Parts tab issues, built from the tab's own container.
//

import Foundation

/// ClickHouse carries the database as a request parameter rather than in the session, and the app
/// moves that parameter whenever any tab runs somewhere else. An unqualified name therefore names
/// whichever database the connection was last pinned to, which for `DROP PARTITION` is data loss in
/// a database the user was not looking at.
internal enum ClickHousePartStatements {
    internal static func qualifiedName(
        database: String,
        table: String,
        quote: (String) -> String
    ) -> String {
        guard !database.isEmpty else { return quote(table) }
        return "\(quote(database)).\(quote(table))"
    }

    internal static func optimize(
        database: String,
        table: String,
        quote: (String) -> String
    ) -> String {
        "OPTIMIZE TABLE \(qualifiedName(database: database, table: table, quote: quote)) FINAL"
    }

    internal static func dropPartition(
        database: String,
        table: String,
        partition: String,
        quote: (String) -> String,
        escape: (String) -> String
    ) -> String {
        let name = qualifiedName(database: database, table: table, quote: quote)
        return "ALTER TABLE \(name) DROP PARTITION '\(escape(partition))'"
    }

    internal static func detachPartition(
        database: String,
        table: String,
        partition: String,
        quote: (String) -> String,
        escape: (String) -> String
    ) -> String {
        let name = qualifiedName(database: database, table: table, quote: quote)
        return "ALTER TABLE \(name) DETACH PARTITION '\(escape(partition))'"
    }

    /// A connection saved with no database of its own has none to name, and ClickHouse then resolves
    /// an unqualified request against its own configured default, which `currentDatabase()` reports.
    /// Comparing against an empty string instead matches nothing and empties the tab.
    private static func databasePredicate(_ database: String, escape: (String) -> String) -> String {
        guard !database.isEmpty else { return "currentDatabase()" }
        return "'\(escape(database))'"
    }

    /// Filtered on the named database rather than `currentDatabase()`, which answers with the
    /// request parameter and so listed another database's parts under this table's name.
    internal static func parts(
        database: String,
        table: String,
        escape: (String) -> String
    ) -> String {
        """
        SELECT partition, name, rows, bytes_on_disk,
               toString(modification_time) AS mod_time, active
        FROM system.parts
        WHERE database = \(databasePredicate(database, escape: escape)) AND table = '\(escape(table))'
        ORDER BY partition, name
        """
    }
}
