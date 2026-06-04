import Foundation

public struct DatabaseType: Hashable, Codable, Identifiable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var id: String { rawValue }
    public var displayName: String { rawValue }

    // MARK: - Known Constants (raw values match macOS for CloudKit compatibility)

    public static let mysql = DatabaseType(rawValue: "MySQL")
    public static let mariadb = DatabaseType(rawValue: "MariaDB")
    public static let postgresql = DatabaseType(rawValue: "PostgreSQL")
    public static let sqlite = DatabaseType(rawValue: "SQLite")
    public static let redis = DatabaseType(rawValue: "Redis")
    public static let mongodb = DatabaseType(rawValue: "MongoDB")
    public static let clickhouse = DatabaseType(rawValue: "ClickHouse")
    public static let mssql = DatabaseType(rawValue: "SQL Server")
    public static let oracle = DatabaseType(rawValue: "Oracle")
    public static let duckdb = DatabaseType(rawValue: "DuckDB")
    public static let cassandra = DatabaseType(rawValue: "Cassandra")
    public static let redshift = DatabaseType(rawValue: "Redshift")
    public static let etcd = DatabaseType(rawValue: "etcd")
    public static let cloudflareD1 = DatabaseType(rawValue: "Cloudflare D1")
    public static let dynamodb = DatabaseType(rawValue: "DynamoDB")
    public static let bigquery = DatabaseType(rawValue: "BigQuery")
    public static let bigQuery = DatabaseType(rawValue: "BigQuery")
    public static let libsql = DatabaseType(rawValue: "libSQL")
    public static let cockroachdb = DatabaseType(rawValue: "CockroachDB")
    public static let scylladb = DatabaseType(rawValue: "ScyllaDB")
    public static let turso = DatabaseType(rawValue: "Turso")

    public static let allKnownTypes: [DatabaseType] = [
        .mysql, .mariadb, .postgresql, .sqlite, .redis, .mongodb,
        .clickhouse, .mssql, .oracle, .duckdb, .cassandra, .redshift,
        .cockroachdb, .scylladb, .etcd, .cloudflareD1, .dynamodb,
        .bigQuery, .libsql, .turso
    ]
}
