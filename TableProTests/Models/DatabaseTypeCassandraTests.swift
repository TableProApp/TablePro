import Testing
@testable import TablePro

@Suite("DatabaseType Cassandra Properties")
struct DatabaseTypeCassandraTests {
    @Test("Cassandra raw value is Cassandra")
    func cassandraRawValue() {
        #expect(DatabaseType.cassandra.rawValue == "Cassandra")
    }

    @Test("ScyllaDB raw value is ScyllaDB")
    func scylladbRawValue() {
        #expect(DatabaseType.scylladb.rawValue == "ScyllaDB")
    }

    @Test("Cassandra pluginTypeId is Cassandra")
    func cassandraPluginTypeId() {
        #expect(DatabaseType.cassandra.pluginTypeId == "Cassandra")
    }

    @Test("ScyllaDB pluginTypeId is Cassandra")
    func scylladbPluginTypeId() {
        #expect(DatabaseType.scylladb.pluginTypeId == "Cassandra")
    }

    @Test("Cassandra default port is 9042")
    func cassandraDefaultPort() {
        #expect(DatabaseType.cassandra.defaultPort == 9_042)
    }

    @Test("ScyllaDB default port is 9042")
    func scylladbDefaultPort() {
        #expect(DatabaseType.scylladb.defaultPort == 9_042)
    }

    @Test("Cassandra does not require authentication")
    func cassandraRequiresAuthentication() {
        #expect(DatabaseType.cassandra.requiresAuthentication == false)
    }

    @Test("ScyllaDB does not require authentication")
    func scylladbRequiresAuthentication() {
        #expect(DatabaseType.scylladb.requiresAuthentication == false)
    }

    @Test("Cassandra does not support foreign keys")
    func cassandraSupportsForeignKeys() {
        #expect(DatabaseType.cassandra.supportsForeignKeys == false)
    }

    @Test("ScyllaDB does not support foreign keys")
    func scylladbSupportsForeignKeys() {
        #expect(DatabaseType.scylladb.supportsForeignKeys == false)
    }

    @Test("Cassandra supports schema editing")
    func cassandraSupportsSchemaEditing() {
        #expect(DatabaseType.cassandra.supportsSchemaEditing == true)
    }

    @Test("ScyllaDB supports schema editing")
    func scylladbSupportsSchemaEditing() {
        #expect(DatabaseType.scylladb.supportsSchemaEditing == true)
    }

    @Test("Cassandra icon name is cassandra-icon")
    func cassandraIconName() {
        #expect(DatabaseType.cassandra.iconName == "cassandra-icon")
    }

    @Test("ScyllaDB icon name is cassandra-icon")
    func scylladbIconName() {
        #expect(DatabaseType.scylladb.iconName == "cassandra-icon")
    }

    @Test("Cassandra is a downloadable plugin")
    func cassandraIsDownloadablePlugin() {
        #expect(DatabaseType.cassandra.isDownloadablePlugin == true)
    }

    @Test("ScyllaDB is a downloadable plugin")
    func scylladbIsDownloadablePlugin() {
        #expect(DatabaseType.scylladb.isDownloadablePlugin == true)
    }

    @Test("Cassandra included in allCases")
    func cassandraIncludedInAllCases() {
        #expect(DatabaseType.allCases.contains(.cassandra))
    }

    @Test("ScyllaDB included in allCases")
    func scylladbIncludedInAllCases() {
        #expect(DatabaseType.allCases.contains(.scylladb))
    }
}
