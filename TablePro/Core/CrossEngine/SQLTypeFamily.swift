//
//  SQLTypeFamily.swift
//  TablePro
//
//  Which engines spell their column types the same way.
//
//  Not the same grouping as `SqlDialect`, which exists to lex a script and puts
//  DuckDB with SQLite because both take its string literals. Their type systems
//  are not related at all: DuckDB has `HUGEINT`, `STRUCT`, `LIST` and a real
//  `TIMESTAMPTZ`, and SQLite has five storage classes and accepts any spelling
//  at all. Reusing that grouping would have rendered a DuckDB target as SQLite.
//
//  Curated by name, like `SqlDialect.from(databaseTypeId:)` already is, because
//  a type spelling is a fact about an engine and no capability the plugin
//  registry publishes implies it. `DatabaseType` is open, so anything not named
//  here is `.generic` and renders portable ANSI SQL rather than being refused.
//

import Foundation

internal enum SQLTypeFamily: String, Hashable, Sendable, CaseIterable {
    case mysql
    case postgres
    case sqlite
    case mssql
    case oracle
    case clickhouse
    case duckdb
    case generic

    internal static func of(_ type: DatabaseType) -> SQLTypeFamily {
        familiesByTypeId[type.rawValue] ?? .generic
    }

    /// Whether a copy between these two needs its types translated at all.
    internal static func needsTranslation(from source: DatabaseType, to target: DatabaseType) -> Bool {
        guard source != target else { return false }
        let sourceFamily = of(source)
        return sourceFamily != of(target) || sourceFamily == .generic
    }

    private static let familiesByTypeId: [String: SQLTypeFamily] = [
        "MySQL": .mysql,
        "MariaDB": .mysql,
        "PostgreSQL": .postgres,
        "Redshift": .postgres,
        "CockroachDB": .postgres,
        "PGlite": .postgres,
        "AlloyDB": .postgres,
        "Citus": .postgres,
        "Greenplum": .postgres,
        "SQLite": .sqlite,
        "libSQL": .sqlite,
        "Turso": .sqlite,
        "Cloudflare D1": .sqlite,
        "SQL Server": .mssql,
        "Oracle": .oracle,
        "Dameng": .oracle,
        "ClickHouse": .clickhouse,
        "DuckDB": .duckdb
    ]
}
