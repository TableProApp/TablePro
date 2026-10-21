//
//  SQLiteMasterQueries.swift
//  TableProPluginKit
//
//  sqlite_master reads shared by every SQLite-compatible driver.
//

import Foundation

// swiftlint:disable inclusive_language
/// SQLite, LibSQL and Cloudflare D1 are three bundles reading one catalog. Three copies of this
/// query would be three chances for the per-table list and the schema-wide list to drift apart.
public enum SQLiteMasterQueries {
// swiftlint:enable inclusive_language
    // `.literal` compares code units: the default compares grapheme clusters and skips a quote a
    // combining mark follows, which then ends the literal early.
    public static func escapeLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''", options: .literal)
    }

    public static let attachedDatabasesQuery = """
        SELECT name FROM pragma_database_list
        WHERE name NOT IN ('main', 'temp')
        ORDER BY seq
        """

    /// Nil, empty and `main` all name the opened file, whose objects the app keeps with no schema.
    public static func attachedSchema(_ schema: String?) -> String? {
        guard let schema, !schema.isEmpty, schema.caseInsensitiveCompare("main") != .orderedSame else { return nil }
        return schema
    }

    public static func quoteIdentifier(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\"", options: .literal))\""
    }

    public static func catalogTable(schema: String?) -> String {
        guard let attached = attachedSchema(schema) else { return "sqlite_master" }
        return "\(quoteIdentifier(attached)).sqlite_master"
    }

    /// The trailing schema argument a table-valued pragma takes, `, 'auth'`, or nothing for the
    /// opened file. Without one a pragma searches every database for the table, temporary ones first.
    public static func pragmaSchemaArgument(_ schema: String?) -> String {
        guard let attached = attachedSchema(schema) else { return "" }
        return ", '\(escapeLiteral(attached))'"
    }

    public static func qualifiedTable(_ table: String, schema: String?, quote: (String) -> String) -> String {
        guard let attached = attachedSchema(schema) else { return quote(table) }
        return "\(quote(attached)).\(quote(table))"
    }

    /// `excludeNameGlob` hides a host's own bookkeeping triggers, which Cloudflare D1 prefixes
    /// `_cf_` and which the user did not create and cannot edit.
    public static func triggerList(table: String? = nil, excludeNameGlob: String? = nil) -> String {
        triggerList(table: table, schema: nil, excludeNameGlob: excludeNameGlob)
    }

    public static func triggerList(table: String?, schema: String?, excludeNameGlob: String?) -> String {
        let tablePredicate = table.map { "AND tbl_name = '\(escapeLiteral($0))'" } ?? ""
        let excludePredicate = excludeNameGlob.map { "AND name NOT GLOB '\(escapeLiteral($0))'" } ?? ""
        return """
            SELECT name, tbl_name, sql FROM \(catalogTable(schema: schema))
            WHERE type = 'trigger' \(tablePredicate) \(excludePredicate)
            ORDER BY tbl_name, name
            """
    }

    /// SQLite stores the CREATE TRIGGER text and nothing else about the trigger, so timing, event
    /// and orientation are read back out of that text rather than from columns.
    public static func trigger(name: String, table: String?, sql: String) -> PluginTriggerInfo {
        trigger(name: name, table: table, schema: nil, sql: sql)
    }

    public static func trigger(name: String, table: String?, schema: String?, sql: String) -> PluginTriggerInfo {
        let parsed = TriggerSQLParser.timingAndEvent(from: sql)
        return PluginTriggerInfo(
            name: name,
            table: table,
            schema: attachedSchema(schema),
            timing: parsed.timing,
            event: parsed.event,
            orientation: "ROW",
            statement: sql,
            definition: sql,
            enabled: nil,
            attributes: []
        )
    }
}
