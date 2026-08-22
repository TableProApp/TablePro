//
//  SQLiteMasterQueries.swift
//  TableProPluginKit
//
//  sqlite_master reads shared by every SQLite-compatible driver.
//

import Foundation

/// SQLite, LibSQL and Cloudflare D1 are three bundles reading one catalog. Three copies of this
/// query would be three chances for the per-table list and the schema-wide list to drift apart.
public enum SQLiteMasterQueries {
    public static func escapeLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    /// `excludeNameGlob` hides a host's own bookkeeping triggers, which Cloudflare D1 prefixes
    /// `_cf_` and which the user did not create and cannot edit.
    public static func triggerList(table: String? = nil, excludeNameGlob: String? = nil) -> String {
        let tablePredicate = table.map { "AND tbl_name = '\(escapeLiteral($0))'" } ?? ""
        let excludePredicate = excludeNameGlob.map { "AND name NOT GLOB '\(escapeLiteral($0))'" } ?? ""
        return """
            SELECT name, tbl_name, sql FROM sqlite_master
            WHERE type = 'trigger' \(tablePredicate) \(excludePredicate)
            ORDER BY tbl_name, name
            """
    }

    /// SQLite stores the CREATE TRIGGER text and nothing else about the trigger, so timing, event
    /// and orientation are read back out of that text rather than from columns.
    public static func trigger(name: String, table: String?, sql: String) -> PluginTriggerInfo {
        let parsed = TriggerSQLParser.timingAndEvent(from: sql)
        return PluginTriggerInfo(
            name: name,
            table: table,
            schema: nil,
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
