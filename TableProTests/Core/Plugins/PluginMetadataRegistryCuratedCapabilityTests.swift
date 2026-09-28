//
//  PluginMetadataRegistryCuratedCapabilityTests.swift
//  TableProTests
//
//  A capability with no DriverPlugin static is curated per type. buildMetadataSnapshot has to
//  carry it over from the built-in entry, or loading the plugin resets it to the struct default
//  and the curated value never reaches the app (#2108).
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class MockDuckDBPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock DuckDB"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Stands in for the registry-distributed DuckDB plugin"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "DuckDB"
    static let databaseDisplayName = "DuckDB"
    static let iconName = "duckdb-icon"
    static let defaultPort = 9_494

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

private final class MockMongoDBPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock MongoDB"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Stands in for the registry-distributed MongoDB plugin"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "MongoDB"
    static let databaseDisplayName = "MongoDB"
    static let iconName = "mongodb-icon"
    static let defaultPort = 27_017

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

private final class MockSpannerPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock Spanner"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Stands in for the registry-distributed Spanner plugin"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "Spanner"
    static let databaseDisplayName = "Google Cloud Spanner"
    static let iconName = "spanner-icon"
    static let defaultPort = 0
    static let defaultSchemaName = "(default)"

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

private final class MockMySQLPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock MySQL"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Stands in for the bundled MySQL plugin"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "MySQL"
    static let databaseDisplayName = "MySQL"
    static let iconName = "mysql-icon"
    static let defaultPort = 3_306

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

private final class MockCassandraPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock Cassandra"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Stands in for the registry-distributed Cassandra plugin"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "Cassandra"
    static let databaseDisplayName = "Cassandra / ScyllaDB"
    static let iconName = "cassandra-icon"
    static let defaultPort = 9_042

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

private final class MockDynamoDBPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock DynamoDB"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Stands in for the registry-distributed DynamoDB plugin"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "DynamoDB"
    static let databaseDisplayName = "Amazon DynamoDB"
    static let iconName = "dynamodb-icon"
    static let defaultPort = 0

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

private final class MockTrinoPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock Trino"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Stands in for the registry-distributed Trino plugin"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "Trino"
    static let databaseDisplayName = "Trino"
    static let iconName = "trino-icon"
    static let defaultPort = 8_080

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

private final class MockClickHousePlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock ClickHouse"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Stands in for the bundled ClickHouse plugin"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "ClickHouse"
    static let databaseDisplayName = "ClickHouse"
    static let iconName = "clickhouse-icon"
    static let defaultPort = 8_123

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

private final class MockMSSQLPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock MSSQL"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Stands in for the registry-distributed SQL Server plugin"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "SQL Server"
    static let databaseDisplayName = "SQL Server"
    static let iconName = "mssql-icon"
    static let defaultPort = 1_433

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

private final class MockUnknownPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock Unknown"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "A plugin type the app has no curated entry for"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "NoCuratedEntryDB"
    static let databaseDisplayName = "No Curated Entry"
    static let iconName = "cylinder.fill"
    static let defaultPort = 1_234

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

@Suite("PluginMetadataRegistry curated capabilities", .serialized)
struct PluginMetadataRegistryCuratedCapabilityTests {
    @Test("DuckDB stays unpoolable when its plugin registers")
    func duckDBKeepsItsPoolingOptOut() {
        let registry = PluginMetadataRegistry.shared

        let built = registry.buildMetadataSnapshot(from: MockDuckDBPlugin.self)

        #expect(
            built.capabilities.supportsConnectionPooling == false,
            "A second duckdb_open is a different database, so metadata must stay on the session driver (#2108)"
        )
    }

    @Test("DuckDB keeps its file signatures when its plugin registers")
    func duckDBKeepsItsFileSignatures() {
        let registry = PluginMetadataRegistry.shared

        let built = registry.buildMetadataSnapshot(from: MockDuckDBPlugin.self)

        #expect(
            built.schema.fileSignatures == [.magic("DUCK", at: 8).andZeroes(at: 14, count: 6)],
            "No DriverPlugin declares a signature, so loading the plugin would otherwise erase it"
        )
    }

    @Test("MongoDB keeps its database-scoped authentication when its plugin registers")
    func mongoDBKeepsDatabaseScopedAuthentication() {
        let registry = PluginMetadataRegistry.shared

        let built = registry.buildMetadataSnapshot(from: MockMongoDBPlugin.self)

        #expect(built.capabilities.authenticationIsDatabaseScoped == true)
    }

    @Test("MongoDB keeps its sampled columns and its structure matrix when its plugin registers")
    func mongoDBKeepsSampledColumnsAndStructureMatrix() {
        let registry = PluginMetadataRegistry.shared

        let built = registry.buildMetadataSnapshot(from: MockMongoDBPlugin.self)

        #expect(
            built.capabilities.columnsAreSampled == true,
            "A structure sync would read a field missing from one sample as a field to remove"
        )
        #expect(StructureEditEligibility.allows(.renameColumn, on: .table, matrix: built.structureEditing.structureEdits))
        #expect(StructureEditEligibility.allows(.dropColumn, on: .table, matrix: built.structureEditing.structureEdits))
    }

    @Test("DynamoDB keeps its full-scan count when its plugin registers")
    func dynamoDBKeepsItsFullScanCount() {
        let registry = PluginMetadataRegistry.shared

        let built = registry.buildMetadataSnapshot(from: MockDynamoDBPlugin.self)

        #expect(
            built.capabilities.exactRowCountIsFullScan == true,
            "Every automatic count would be a Scan of the whole table that AWS bills for"
        )
    }

    /// None of these has a `DriverPlugin` static, so a plugin that registers would reset them to the struct
    /// defaults: counts on every open that read every partition, a header sort CQL refuses, and Match Any.
    @Test("Cassandra keeps its count, sort and filter limits when its plugin registers")
    func cassandraKeepsItsCuratedQueryLimits() {
        let built = PluginMetadataRegistry.shared.buildMetadataSnapshot(from: MockCassandraPlugin.self)

        #expect(built.capabilities.exactRowCountIsFullScan == true)
        #expect(built.capabilities.supportsColumnSort == false)
        #expect(built.capabilities.supportsMatchAnyFilters == false)
        #expect(built.capabilities.pagination == .leadingRowsOnly(maximumRows: nil))
    }

    @Test("ScyllaDB declares the same query limits as Cassandra on its own curated entry")
    func scyllaDBDeclaresTheCassandraQueryLimits() {
        let registry = PluginMetadataRegistry.shared
        let cassandra = registry.snapshot(forRegisteredTypeId: "Cassandra")?.capabilities
        let scylla = registry.snapshot(forRegisteredTypeId: "ScyllaDB")?.capabilities

        #expect(scylla?.exactRowCountIsFullScan == true)
        #expect(scylla?.supportsColumnSort == false)
        #expect(scylla?.supportsMatchAnyFilters == false)
        #expect(scylla?.pagination == .leadingRowsOnly(maximumRows: nil))
        #expect(scylla?.exactRowCountIsFullScan == cassandra?.exactRowCountIsFullScan)
        #expect(scylla?.supportsColumnSort == cassandra?.supportsColumnSort)
        #expect(scylla?.supportsMatchAnyFilters == cassandra?.supportsMatchAnyFilters)
    }

    /// Measured: `ADD … NOT NULL` and `COMMENT ON COLUMN` are syntax errors, `ALTER … TYPE` is refused, and only a
    /// primary key column can be renamed, so the Structure tab offers adding and dropping a column and nothing else.
    @Test("Cassandra and ScyllaDB offer only the column edits CQL can run", arguments: ["Cassandra", "ScyllaDB"])
    func cassandraStructureEdits(typeId: String) throws {
        let snapshot = try #require(PluginMetadataRegistry.shared.snapshot(forRegisteredTypeId: typeId))
        let matrix = snapshot.structureEditing.structureEdits

        #expect(StructureEditEligibility.allows(.addColumn, on: .table, matrix: matrix))
        #expect(StructureEditEligibility.allows(.dropColumn, on: .table, matrix: matrix))
        for operation in [StructureEditOperation.renameColumn, .changeColumnType, .setNotNull, .commentOnColumn,
                          .addIndex, .dropIndex] {
            #expect(!StructureEditEligibility.allows(operation, on: .table, matrix: matrix), "\(operation)")
        }
        #expect(snapshot.schema.structureColumnFields == [.name, .type])
        #expect(snapshot.capabilities.supportsAddIndex == false)
        #expect(snapshot.capabilities.supportsRoutines)
        #expect(snapshot.capabilities.supportsDatabaseTriggerBrowse)
    }

    @Test("Cassandra keeps its structure edits when its plugin registers")
    func cassandraKeepsStructureEdits() {
        let built = PluginMetadataRegistry.shared.buildMetadataSnapshot(from: MockCassandraPlugin.self)
        #expect(!StructureEditEligibility.allows(.renameColumn, on: .table, matrix: built.structureEditing.structureEdits))
    }

    @Test("MySQL keeps browsing only inside a selected database when its plugin registers")
    func mySQLKeepsBrowsingRequiresSelectedDatabase() {
        let registry = PluginMetadataRegistry.shared

        let built = registry.buildMetadataSnapshot(from: MockMySQLPlugin.self)

        #expect(built.capabilities.browsingRequiresSelectedDatabase == true)
    }

    /// A MySQL-protocol session opened with no database has none at all, so it lists nothing until
    /// one is chosen. Databend's session falls back to its `default` database instead.
    @Test("Only the MySQL engines with no default database require a selected database to browse")
    func browsingRequiresSelectedDatabasePerEngine() {
        let registry = PluginMetadataRegistry.shared

        for typeId in ["MySQL", "MariaDB", "TiDB", "OceanBase"] {
            #expect(
                registry.snapshot(forRegisteredTypeId: typeId)?.capabilities.browsingRequiresSelectedDatabase == true,
                "\(typeId)"
            )
        }
        for typeId in ["Databend", "PostgreSQL", "ClickHouse"] {
            #expect(
                (registry.snapshot(forRegisteredTypeId: typeId)?.capabilities.browsingRequiresSelectedDatabase ?? false)
                    == false,
                "\(typeId)"
            )
        }
    }

    @Test("Spanner keeps its implicit schema when its plugin registers")
    func spannerKeepsItsImplicitSchema() {
        let registry = PluginMetadataRegistry.shared

        let built = registry.buildMetadataSnapshot(from: MockSpannerPlugin.self)

        #expect(built.schema.implicitSchemaName == "(default)")
        #expect(built.schema.defaultSchemaName == "(default)")
    }

    @Test("An engine with a named default schema declares no implicit schema")
    func duckDBHasNoImplicitSchema() {
        let registry = PluginMetadataRegistry.shared

        let built = registry.buildMetadataSnapshot(from: MockDuckDBPlugin.self)

        #expect(built.schema.implicitSchemaName == nil)
    }

    @Test("Trino keeps its TLS port, system trust and no plaintext fallback when its plugin registers")
    func trinoKeepsItsTLSCapabilities() {
        let built = PluginMetadataRegistry.shared.buildMetadataSnapshot(from: MockTrinoPlugin.self)

        #expect(built.capabilities.tlsImpliedPorts == [443])
        #expect(built.capabilities.verifiesServerWithSystemTrust == true)
        #expect(built.capabilities.supportsOpportunisticTLS == false)
    }

    @Test("ClickHouse keeps its TLS ports and system trust when its plugin registers")
    func clickHouseKeepsItsTLSCapabilities() {
        let built = PluginMetadataRegistry.shared.buildMetadataSnapshot(from: MockClickHousePlugin.self)

        #expect(built.capabilities.tlsImpliedPorts == [8_443, 443])
        #expect(built.capabilities.verifiesServerWithSystemTrust == true)
    }

    @Test("SQL Server keeps its missing certificate fields when its plugin registers")
    func mssqlKeepsItsCertificateFieldOptOut() {
        let built = PluginMetadataRegistry.shared.buildMetadataSnapshot(from: MockMSSQLPlugin.self)

        #expect(built.capabilities.supportsPerConnectionCertificatePaths == false)
    }

    @Test("A plugin with no curated entry falls back to the defaults")
    func unknownPluginUsesTheStructDefaults() {
        let registry = PluginMetadataRegistry.shared
        #expect(registry.snapshot(forRegisteredTypeId: MockUnknownPlugin.databaseTypeId) == nil)

        let built = registry.buildMetadataSnapshot(from: MockUnknownPlugin.self)

        #expect(built.capabilities.supportsConnectionPooling == true)
        #expect(built.capabilities.authenticationIsDatabaseScoped == false)
        #expect(built.capabilities.browsingRequiresSelectedDatabase == false)
        #expect(built.capabilities.exactRowCountIsFullScan == false)
        #expect(built.capabilities.supportsColumnSort == true)
        #expect(built.capabilities.supportsMatchAnyFilters == true)
        #expect(built.capabilities.columnsAreSampled == false)
        #expect(built.capabilities.tlsImpliedPorts.isEmpty)
        #expect(built.capabilities.verifiesServerWithSystemTrust == false)
        #expect(built.capabilities.supportsPerConnectionCertificatePaths == true)
        #expect(built.schema.implicitSchemaName == nil)
    }
}
