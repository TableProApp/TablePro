//
//  PluginMetadataRegistryTypeCountTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// The number of engines TablePro offers is published in three places that cannot see each other:
/// this registry, `docs/snippets/driver-counts.mdx`, and the marketing site. Nothing at runtime
/// reconciles them, and by August 2026 they read 28, 27 and 25 at once.
///
/// The answer is 29, and the reason it read 28 for a while is worth keeping. Turso is served by
/// the libSQL plugin and was the only alias in `reverseTypeIndex` with no curated entry of its
/// own, so it was the only type the picker could not offer before its plugin was installed.
/// ScyllaDB is the shape every other alias already had: an alias of Cassandra with a curated
/// entry all the same. Turso now matches it, and 29 falls out of the count rather than being
/// asserted on top of it. Do not "correct" this back to 28 by deleting that entry.
///
/// A failure here means a driver was added or removed, which is a deliberate act. Update
/// `expectedTypeIds`, then `docs/snippets/driver-counts.mdx`, the `and N more` count in the
/// `docs/index.mdx` frontmatter, and the engine count on tablepro.app in the same change.
/// `docs/scripts/check-docs-against-source.py` reads the registry and holds the docs half.
///
/// The count is taken from the built-in defaults rather than from `allRegisteredTypeIds()`.
/// Both answer 29 under XCTest, where no plugin bundle ever loads, but the registry is a
/// process-global singleton and suites that register a synthetic type run alongside this one.
@MainActor
@Suite("PluginMetadataRegistry engine count")
struct PluginMetadataRegistryTypeCountTests {
    private static let expectedTypeIds: Set<String> = [
        "Beancount", "BigQuery", "Cassandra", "ClickHouse", "Cloudflare D1", "CockroachDB",
        "Dameng", "DuckDB", "DynamoDB", "Elasticsearch", "etcd", "Kafka", "libSQL", "MariaDB",
        "MongoDB", "MySQL", "Oracle", "PGlite", "PostgreSQL", "Redis", "Redshift", "ScyllaDB",
        "Snowflake", "SQL Server", "SQLite", "SurrealDB", "Teradata", "Trino", "Turso"
    ]

    private static func builtInTypeIds() -> Set<String> {
        let curated = PluginMetadataRegistry.curatedDefaults().map(\.typeId)
        let registry = PluginMetadataRegistry.shared.registryPluginDefaults().map(\.typeId)
        return Set(curated + registry)
    }

    @Test("The app ships 29 database types before any plugin loads")
    func builtInDefaultsCoverTwentyNineTypes() {
        let ids = Self.builtInTypeIds()
        #expect(ids.count == 29)
        #expect(ids == Self.expectedTypeIds)
    }

    @Test("Every built-in type is offered by the registry")
    func registrySurfacesEveryBuiltInType() {
        let registered = Set(PluginMetadataRegistry.shared.allRegisteredTypeIds())
        #expect(Self.expectedTypeIds.isSubset(of: registered))
    }

    /// An alias is a type of its own to the reader and a route to someone else's plugin to the
    /// driver lookup, and it needs both halves. Without a curated entry the picker cannot offer
    /// it until the serving plugin is installed, and once installed it inherits the primary's
    /// name, icon and tagline. Turso had exactly that gap.
    private static let aliasesToTheirPlugin = [
        "MariaDB": "MySQL",
        "Redshift": "PostgreSQL",
        "CockroachDB": "PostgreSQL",
        "PGlite": "PostgreSQL",
        "ScyllaDB": "Cassandra",
        "Turso": "libSQL"
    ]

    @Test("Every alias carries a curated entry of its own")
    func everyAliasIsAnEngineInItsOwnRight() {
        let builtIn = Self.builtInTypeIds()
        for alias in Self.aliasesToTheirPlugin.keys {
            #expect(builtIn.contains(alias), "\(alias) has no curated entry")
            #expect(PluginMetadataRegistry.shared.snapshot(forRegisteredTypeId: alias) != nil)
        }
    }

    @Test("Every alias still routes to the plugin that serves it")
    func everyAliasResolvesToItsPlugin() {
        for (alias, plugin) in Self.aliasesToTheirPlugin {
            #expect(PluginMetadataRegistry.shared.pluginTypeId(for: alias) == plugin)
        }
    }

    /// `isDownloadablePlugin` is a fact about the plugin binary, so an alias answers with its
    /// serving plugin's flag. Turso is served by libSQL, which is a registry download.
    @Test("Turso reports its serving plugin as downloadable")
    func tursoIsADownloadablePlugin() {
        #expect(DatabaseType.turso.isDownloadablePlugin)
        #expect(DatabaseType.turso.isDownloadablePlugin == DatabaseType.libsql.isDownloadablePlugin)
    }
}
