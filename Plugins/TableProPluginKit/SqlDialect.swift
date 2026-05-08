import Foundation

public enum SqlDialect: String, Sendable, CaseIterable {
    case postgres
    case mysql
    case sqlite
    case generic

    public static func from(databaseTypeId: String) -> SqlDialect {
        switch databaseTypeId {
        case "PostgreSQL", "Redshift", "Greenplum", "AlloyDB", "Citus", "CockroachDB":
            return .postgres
        case "MySQL", "MariaDB":
            return .mysql
        case "SQLite", "libSQL", "Turso", "DuckDB", "Cloudflare D1":
            return .sqlite
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

    public var supportsEscapeStringPrefix: Bool {
        self == .postgres
    }

    public var supportsAdjacentStringConcatenation: Bool {
        self != .mysql
    }
}
