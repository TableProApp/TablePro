//
//  SQLDDLFallbackPolicy.swift
//  TableProConnectionLibrary
//

import Foundation

/// Whether an app may build `DROP <kind> <name>` or `TRUNCATE TABLE <name>` itself for an engine.
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
/// here per engine.
///
/// Keyed by the raw database type id rather than by a `DatabaseType`, because the two apps do not
/// share that type: the Mac app has `TablePro/Models/Connection/DatabaseType.swift` and iOS has
/// `TableProCoreTypes.DatabaseType`, two separate structs whose constant lists have already drifted
/// apart. This target is one of the five both apps link, and it carries no plugin ABI, so a string
/// key here is what lets one list serve both. It follows `SqlDialect.from(databaseTypeId:)`, which
/// is keyed the same way for the same reason.
public enum SQLDDLFallbackPolicy {
    /// Engines with no SQL DDL to fall back on.
    ///
    /// Most of these have a driver that answers both hooks, so an app never reaches the fallback for
    /// them. They are listed anyway, because a driver answers per object kind: Typesense returns nil
    /// for anything that is not a collection, and without this an app would answer that with
    /// `DROP VIEW`.
    public static let engineIdsWithoutSQLDDL: Set<String> = [
        "Elasticsearch",
        "Typesense",
        "Weaviate",
        "Kafka",
        "etcd",
        "Redis",
        "MongoDB",
        "SurrealDB",
        "DynamoDB",
        "Beancount",
    ]

    /// True when `DROP`/`TRUNCATE` built by the app is something this engine could run.
    public static func allowsGeneratedDDL(databaseTypeId: String) -> Bool {
        !engineIdsWithoutSQLDDL.contains(databaseTypeId)
    }
}
