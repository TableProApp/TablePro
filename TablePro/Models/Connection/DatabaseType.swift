//
//  DatabaseType.swift
//  TablePro
//

import Foundation

struct DatabaseType: Hashable, Identifiable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    var id: String { rawValue }
    var displayName: String { rawValue }
}

extension DatabaseType {
    // Built-in types (bundled plugins)
    static let mysql = DatabaseType(rawValue: "MySQL")
    static let mariadb = DatabaseType(rawValue: "MariaDB")
    static let postgresql = DatabaseType(rawValue: "PostgreSQL")
    static let sqlite = DatabaseType(rawValue: "SQLite")
    static let redshift = DatabaseType(rawValue: "Redshift")
    static let cockroachdb = DatabaseType(rawValue: "CockroachDB")
    static let pglite = DatabaseType(rawValue: "PGlite")

    // Registry-distributed types (known plugins, downloadable separately)
    static let mongodb = DatabaseType(rawValue: "MongoDB")
    static let redis = DatabaseType(rawValue: "Redis")
    static let mssql = DatabaseType(rawValue: "SQL Server")
    static let oracle = DatabaseType(rawValue: "Oracle")
    static let snowflake = DatabaseType(rawValue: "Snowflake")
    static let dameng = DatabaseType(rawValue: "Dameng")
    static let clickhouse = DatabaseType(rawValue: "ClickHouse")
    static let duckdb = DatabaseType(rawValue: "DuckDB")
    static let cassandra = DatabaseType(rawValue: "Cassandra")
    static let scylladb = DatabaseType(rawValue: "ScyllaDB")
    static let etcd = DatabaseType(rawValue: "etcd")
    static let cloudflareD1 = DatabaseType(rawValue: "Cloudflare D1")
    static let dynamodb = DatabaseType(rawValue: "DynamoDB")
    static let bigQuery = DatabaseType(rawValue: "BigQuery")
    static let libsql = DatabaseType(rawValue: "libSQL")
    static let turso = DatabaseType(rawValue: "Turso")
    static let beancount = DatabaseType(rawValue: "Beancount")
    static let elasticsearch = DatabaseType(rawValue: "Elasticsearch")
    static let surrealdb = DatabaseType(rawValue: "SurrealDB")
    static let typesense = DatabaseType(rawValue: "Typesense")
    static let teradata = DatabaseType(rawValue: "Teradata")
    static let trino = DatabaseType(rawValue: "Trino")
}

extension DatabaseType: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
