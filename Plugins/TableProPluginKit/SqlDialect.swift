import Foundation

public enum SqlDialect: String, Sendable, CaseIterable {
    case postgres
    case mysql
    case sqlite
    case oracle
    case generic

    public static func from(databaseTypeId: String) -> SqlDialect {
        switch databaseTypeId {
        case "PostgreSQL", "Redshift", "Greenplum", "AlloyDB", "Citus", "CockroachDB", "PGlite":
            return .postgres
        case "MySQL", "MariaDB", "TiDB", "OceanBase":
            return .mysql
        case "SQLite", "libSQL", "Turso", "DuckDB", "Cloudflare D1":
            return .sqlite
        case "Oracle":
            return .oracle
        default:
            return .generic
        }
    }

    public var requiresBackslashEscapesInSingleQuotes: Bool {
        self == .mysql
    }

    public var supportsDollarQuotes: Bool {
        self == .postgres
    }

    public var supportsHashLineComments: Bool {
        self == .mysql
    }

    public var supportsEscapeStringPrefix: Bool {
        self == .postgres
    }

    public var supportsAdjacentStringConcatenation: Bool {
        self != .mysql
    }

    /// Oracle's `q'[...]'` literal, whose body runs to the matching delimiter followed by a quote, so a lone `'`
    /// inside it does not end it.
    public var supportsAlternativeQuoting: Bool {
        self == .oracle
    }

    /// SQL*Plus ends a statement at a line holding only `/`, which is how a PL/SQL unit is terminated in every script
    /// written for SQL*Plus, SQLcl or SQL Developer. The line is a client command, never text the server accepts.
    public var endsStatementsAtSlashLines: Bool {
        self == .oracle
    }
}
