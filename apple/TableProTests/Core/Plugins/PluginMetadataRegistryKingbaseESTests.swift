import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct PluginMetadataRegistryKingbaseESTests {
    @Test("KingbaseES is offered before installation and resolves to its own registry plugin")
    func registryIdentity() throws {
        let registry = PluginMetadataRegistry.shared
        #expect(registry.allRegisteredTypeIds().contains("KingbaseES"))
        #expect(registry.pluginTypeId(for: "KingbaseES") == "KingbaseES")
        #expect(DatabaseType.kingbasees.isDownloadablePlugin)
        let snapshot = try #require(registry.snapshot(forRegisteredTypeId: "KingbaseES"))
        let postgreSQL = try #require(registry.snapshot(forRegisteredTypeId: "PostgreSQL"))
        #expect(snapshot.displayName == "KingbaseES")
        #expect(snapshot.iconName == "cylinder")
        #expect(snapshot.connection.tagline != postgreSQL.connection.tagline)
        #expect(snapshot.defaultPort == 54_321)
        #expect(snapshot.urlSchemes == ["kingbase", "kingbase8"])
        #expect(snapshot.parameterStyle == .dollar)
        #expect(snapshot.schema.systemSchemaNames == PluginMetadataRegistry.kingbaseESSystemSchemaNames)
        #expect(snapshot.capabilities.supportsSchemaSwitching)
        #expect(snapshot.connection.additionalConnectionFields.map(\.id) == ["usePgpass", "connectionOptions"])
    }

    @Test("Both KingbaseES URL schemes keep credentials and route to the dedicated engine", arguments: ["kingbase", "kingbase8"])
    func connectionURLs(scheme: String) throws {
        let parsed = try ConnectionURLParser.parse("\(scheme)://system:pass@localhost:55432/test").get()
        #expect(parsed.type == .kingbasees)
        #expect(parsed.host == "localhost")
        #expect(parsed.port == 55_432)
        #expect(parsed.database == "test")
        #expect(parsed.username == "system")
        #expect(parsed.password == "pass")
    }
}
