//
//  ColumnDefaultVocabulary.swift
//  TablePro
//
//  The default values each engine offers for a column, spelled the way its DDL wants them.
//

import Foundation

/// The menu the Default cell offers, per engine.
///
/// Every `sql` here is the exact text that follows the `DEFAULT` keyword, because that is what the
/// Default field holds. Nothing rewrites it on the way to the server, so an entry that is wrong here is
/// a statement the server rejects.
///
/// Curated in the app and keyed by database type id, the shape `PluginMetadataRegistry.fallbackCategory`
/// already uses. It cannot be keyed by plugin: MySQL and MariaDB share one and spell an expression
/// default differently; PostgreSQL, Redshift, CockroachDB and PGlite share one, and only two of them
/// have `gen_random_uuid()`.
///
/// What belongs here is the vocabulary, not the syntax. MySQL takes a `TEXT` or `JSON` default only in
/// parentheses whatever the value is, so that parenthesising is the MySQL driver's job at the point it
/// writes the clause, where the column's type is known.
///
/// An engine that is not listed gets the literals every SQL dialect shares and no expression section.
/// `DatabaseType` is open, so an unknown plugin has to land somewhere honest rather than be given
/// another engine's vocabulary.
internal enum ColumnDefaultVocabulary {
    static func options(for databaseType: DatabaseType) -> [GridMenuOption] {
        var options: [GridMenuOption] = [.clear(title: String(localized: "No default"))]
        options.append(.value(title: "NULL", sql: "NULL"))
        if offersEmptyString(databaseType) {
            options.append(.value(title: String(localized: "Empty string"), sql: "''"))
        }

        let expressions = expressionSQL(for: databaseType)
        if !expressions.isEmpty {
            options.append(.sectionHeader(String(localized: "Expressions")))
            options.append(contentsOf: expressions.map { .value(title: $0, sql: $0) })
        }

        options.append(.custom(title: String(localized: "Custom…")))
        return options
    }

    /// Oracle treats a zero-length character value as null, so `DEFAULT ''` and `DEFAULT NULL` are the
    /// same statement there and offering both would be a lie. Dameng follows Oracle.
    private static func offersEmptyString(_ databaseType: DatabaseType) -> Bool {
        switch databaseType {
        case .oracle, .dameng: false
        default: true
        }
    }

    private static func expressionSQL(for databaseType: DatabaseType) -> [String] {
        switch databaseType {
        case .mysql:
            return ["CURRENT_TIMESTAMP", "(UUID())", "(CURRENT_DATE)"]
        case .mariadb:
            return ["CURRENT_TIMESTAMP", "uuid()", "curdate()"]
        case .postgresql, .pglite:
            return ["CURRENT_TIMESTAMP", "now()", "CURRENT_DATE", "gen_random_uuid()", "true", "false"]
        case .cockroachdb:
            return ["current_timestamp()", "now()", "gen_random_uuid()", "unique_rowid()", "true", "false"]
        case .redshift:
            return ["GETDATE()", "SYSDATE", "CURRENT_DATE"]
        case .sqlite, .libsql, .turso, .cloudflareD1:
            return ["CURRENT_TIMESTAMP", "CURRENT_DATE", "CURRENT_TIME", "(datetime('now'))", "(unixepoch())"]
        case .duckdb:
            return ["CURRENT_TIMESTAMP", "now()", "uuid()", "nextval('sequence_name')", "true", "false"]
        case .clickhouse:
            return ["now()", "now64(3)", "today()", "generateUUIDv4()"]
        case .mssql:
            return [
                "GETDATE()", "SYSDATETIME()", "GETUTCDATE()", "SYSUTCDATETIME()",
                "CURRENT_TIMESTAMP", "NEWID()", "NEWSEQUENTIALID()"
            ]
        case .oracle:
            return ["SYSDATE", "SYSTIMESTAMP", "CURRENT_TIMESTAMP", "CURRENT_DATE", "SYS_GUID()", "USER"]
        case .dameng:
            return ["SYSDATE", "CURRENT_TIMESTAMP", "CURRENT_DATE", "CURRENT_TIME"]
        case .snowflake:
            return ["CURRENT_TIMESTAMP()", "CURRENT_DATE()", "UUID_STRING()"]
        case .teradata:
            return ["CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "USER"]
        default:
            return []
        }
    }
}
