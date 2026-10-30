import Foundation
@testable import TablePro
import Testing

// A change here also changes the engine counts in TableProApp/docs and on tablepro.app.
@MainActor
struct PluginMetadataRegistryTypeCountTests {
    private static let expectedTypeIds: Set<String> = [
        "Beancount", "BigQuery", "Cassandra", "ClickHouse", "Cloudflare D1", "Cloudflare R2 SQL",
        "CockroachDB", "Dameng", "Databend", "DuckDB", "DynamoDB", "Elasticsearch", "etcd", "Kafka", "KingbaseES",
        "libSQL", "MariaDB", "MongoDB", "MySQL", "Oracle", "PGlite", "PostgreSQL", "Redis", "Redshift",
        "SAP HANA", "ScyllaDB", "Snowflake", "Spanner", "SQL Server", "SQLite", "SurrealDB", "Teradata", "TiDB",
        "Trino", "Presto", "Turso", "Typesense", "Weaviate", "OceanBase", "Firestore", "Firebase Realtime Database", "Bigtable"
    ]

    private static func builtInTypeIds() -> Set<String> {
        let curated = PluginMetadataRegistry.curatedDefaults().map(\.typeId)
        let registry = PluginMetadataRegistry.shared.registryPluginDefaults().map(\.typeId)
        return Set(curated + registry)
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
        "TiDB": "MySQL",
        "Databend": "MySQL",
        "OceanBase": "MySQL",
        "Redshift": "PostgreSQL",
        "CockroachDB": "PostgreSQL",
        "PGlite": "PostgreSQL",
        "ScyllaDB": "Cassandra",
        "Turso": "libSQL",
        "Presto": "Trino",
        "Firebase Realtime Database": "Firestore"
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
