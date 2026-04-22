import Foundation

public struct DatabaseType: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

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
    public static let libsql = DatabaseType(rawValue: "libSQL")

    public static let allKnownTypes: [DatabaseType] = [
        .mysql, .mariadb, .postgresql, .sqlite, .redis, .mongodb,
        .clickhouse, .mssql, .oracle, .duckdb, .cassandra, .redshift,
        .etcd, .cloudflareD1, .dynamodb, .bigquery, .libsql
    ]

    /// Icon name for this database type — asset catalog name (e.g. "mysql-icon") or SF Symbol fallback
    public var iconName: String {
        switch self {
        case .mysql: return "mysql-icon"
        case .mariadb: return "mariadb-icon"
        case .postgresql: return "postgresql-icon"
        case .redshift: return "redshift-icon"
        case .sqlite: return "sqlite-icon"
        case .redis: return "redis-icon"
        case .mongodb: return "mongodb-icon"
        case .clickhouse: return "clickhouse-icon"
        case .mssql: return "mssql-icon"
        case .oracle: return "oracle-icon"
        case .duckdb: return "duckdb-icon"
        case .cassandra: return "cassandra-icon"
        case .etcd: return "etcd-icon"
        case .cloudflareD1: return "cloudflare-d1-icon"
        case .dynamodb: return "dynamodb-icon"
        case .bigquery: return "bigquery-icon"
        case .libsql: return "libsql-icon"
        default: return "externaldrive"
        }
    }

    /// Plugin type ID for plugin lookup.
    /// Multi-type plugins share a single driver: MariaDB -> "MySQL", Redshift -> "PostgreSQL"
    public var pluginTypeId: String {
        switch self {
        case .mariadb: return DatabaseType.mysql.rawValue
        case .redshift: return DatabaseType.postgresql.rawValue
        default: return rawValue
        }
    }
}
