import Testing
@testable import TablePro

@Suite("DatabaseType Cassandra Properties")
struct DatabaseTypeCassandraTests {
    @Test("Cassandra raw value is Cassandra")
    func cassandraRawValue() {
        #expect(.cassandra.rawValue == "Cassandra")
    }

    @Test("ScyllaDB raw value is ScyllaDB")
    func scylladbRawValue() {
        #expect(.scylladb.rawValue == "ScyllaDB")
    }

    @Test("Cassandra pluginTypeId is Cassandra")
    func cassandraPluginTypeId() {
        #expect(.cassandra.pluginTypeId == "Cassandra")
    }

    @Test("ScyllaDB pluginTypeId is Cassandra")
    func scylladbPluginTypeId() {
        #expect(.scylladb.pluginTypeId == "Cassandra")
    }

    @Test("Cassandra default port is 9042")
    func cassandraDefaultPort() {
        #expect(.cassandra.defaultPort == 9_042)
    }

    @Test("ScyllaDB default port is 9042")
    func scylladbDefaultPort() {
        #expect(.scylladb.defaultPort == 9_042)
    }

    @Test("Cassandra does not require authentication")
    func cassandraRequiresAuthentication() {
        #expect(.cassandra.requiresAuthentication == false)
    }

    @Test("ScyllaDB does not require authentication")
    func scylladbRequiresAuthentication() {
        #expect(.scylladb.requiresAuthentication == false)
    }

    @Test("Cassandra does not support foreign keys")
    func cassandraSupportsForeignKeys() {
        #expect(.cassandra.supportsForeignKeys == false)
    }

    @Test("ScyllaDB does not support foreign keys")
    func scylladbSupportsForeignKeys() {
        #expect(.scylladb.supportsForeignKeys == false)
    }

    @Test("Cassandra supports schema editing")
    func cassandraSupportsSchemaEditing() {
        #expect(.cassandra.supportsSchemaEditing == true)
    }

    @Test("ScyllaDB supports schema editing")
    func scylladbSupportsSchemaEditing() {
        #expect(.scylladb.supportsSchemaEditing == true)
    }

    @Test("Cassandra icon name is cassandra-icon")
    func cassandraIconName() {
        #expect(.cassandra.iconName == "cassandra-icon")
    }

    @Test("ScyllaDB icon name is scylladb-icon")
    func scylladbIconName() {
        #expect(.scylladb.iconName == "scylladb-icon")
    }

    @Test("Cassandra is a downloadable plugin")
    func cassandraIsDownloadablePlugin() {
        #expect(.cassandra.isDownloadablePlugin == true)
    }

    @Test("ScyllaDB is a downloadable plugin")
    func scylladbIsDownloadablePlugin() {
        #expect(.scylladb.isDownloadablePlugin == true)
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
