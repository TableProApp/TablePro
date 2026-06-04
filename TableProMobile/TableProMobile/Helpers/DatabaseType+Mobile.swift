import Foundation
import TableProModels

extension DatabaseType {
    var iconName: String {
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
        case .scylladb: return "scylladb-icon"
        case .etcd: return "etcd-icon"
        case .cloudflareD1: return "cloudflare-d1-icon"
        case .dynamodb: return "dynamodb-icon"
        case .bigQuery: return "bigquery-icon"
        case .libsql, .turso: return "libsql-icon"
        case .cockroachdb: return "cockroachdb-icon"
        default: return "externaldrive"
        }
    }

    var defaultPort: String {
        switch self {
        case .mysql, .mariadb: return "3306"
        case .postgresql: return "5432"
        case .redshift: return "5439"
        case .redis: return "6379"
        case .mssql: return "1433"
        case .sqlite, .duckdb: return ""
        default: return "3306"
        }
    }

    var mobileDisplayName: String {
        switch self {
        case .mysql: "MySQL"
        case .mariadb: "MariaDB"
        case .postgresql: "PostgreSQL"
        case .redshift: "Redshift"
        case .sqlite: "SQLite"
        case .duckdb: "DuckDB"
        case .redis: "Redis"
        case .mssql: "SQL Server"
        default: rawValue.uppercased()
        }
    }

    static let mobileSupportedTypes: [DatabaseType] = [
        .mysql,
        .mariadb,
        .postgresql,
        .sqlite,
        .duckdb,
        .redis,
        .mssql
    ]
}
