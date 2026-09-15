//
//  SQLDDLFallbackPolicy.swift
//  TablePro
//

import Foundation

/// Whether the app may build `DROP <kind> <name>` or `TRUNCATE TABLE <name>` itself when an
/// engine's plugin returned no statement of its own.
///
/// `PluginDatabaseDriver` defaults both table operations to nil, and nil says two different things.
/// On MySQL it means the generic DDL is right, which is why eleven SQL plugins never implement
/// either hook. On Elasticsearch it means the engine has no such statement at all, and there the
/// generic DDL is text the driver rejects: `DROP TABLE "test_index"` reached a cluster as a console
/// request and came back "Enter a request like: GET /my-index/_search" (#2884).
///
/// Neither of the engine's other language facts can answer it. DynamoDB writes PartiQL and so
/// declares an editor language of `.sql`, yet PartiQL has no DDL and its driver returns nil from
/// both hooks deliberately. The SQL dialect descriptor cannot answer it either, because it defaults
/// to nil and several engines with ordinary `DROP TABLE` never curate one. So the answer is stated
/// here per engine, and two tests hold it: one walks `DatabaseType.allKnownTypes` so a new engine
/// cannot inherit an answer by accident, and one reads the plugin sources so an engine whose plugin
/// declares a non-SQL editor language can never be missing from this list.
enum SQLDDLFallbackPolicy {
    /// Engines with no SQL DDL to fall back on.
    ///
    /// Most of these have a plugin that answers both hooks, so the app never reaches the fallback
    /// for them. They are listed anyway, because a plugin answers per object kind: Typesense
    /// returns nil for anything that is not a collection, and without this the app would answer
    /// that with `DROP VIEW`.
    static let enginesWithoutSQLDDL: Set<DatabaseType> = [
        .elasticsearch,
        .typesense,
        .weaviate,
        .kafka,
        .etcd,
        .redis,
        .mongodb,
        .surrealdb,
        .dynamodb,
        .beancount,
    ]

    /// True when `DROP`/`TRUNCATE` built by the app is something this engine could run.
    static func allowsGeneratedDDL(for databaseType: DatabaseType) -> Bool {
        !enginesWithoutSQLDDL.contains(databaseType)
    }
}
