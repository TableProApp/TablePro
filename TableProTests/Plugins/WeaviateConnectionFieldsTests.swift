import Foundation
@testable import TablePro
import TableProPluginKit
import TableProWeaviateCore
import Testing

@Suite("Weaviate registry snapshot")
struct WeaviateRegistrySnapshotTests {
    private func snapshot() throws -> PluginMetadataSnapshot {
        let defaults = PluginMetadataRegistry.shared.registryPluginDefaults()
        return try #require(defaults.first { $0.typeId == "Weaviate" }).snapshot
    }

    @Test("Weaviate is a collection engine on port 8080 with no SQL dialect")
    func connectionShape() throws {
        let snapshot = try snapshot()
        #expect(snapshot.defaultPort == 8_080)
        #expect(snapshot.editor.sqlDialect == nil)
        #expect(snapshot.queryLanguageName == "GraphQL")
        #expect(snapshot.schema.tableEntityName == "Collections")
        #expect(snapshot.schema.defaultPrimaryKeyColumn == "uuid")
        #expect(snapshot.schema.immutableColumns == ["uuid", "vector"])
        #expect(!snapshot.supportsForeignKeys)
        #expect(!snapshot.capabilities.supportsSSH)
        #expect(snapshot.capabilities.supportsSSL)
        #expect(snapshot.connection.category == .document)
        #expect(snapshot.iconName == "weaviate-icon")
    }

    @Test("Auth field ids are Weaviate-prefixed and do not collide with Elasticsearch")
    func authFieldIdsArePrefixed() throws {
        let ids = try snapshot().connection.additionalConnectionFields.map(\.id)
        #expect(ids == [
            WeaviateFieldID.authMethod,
            WeaviateFieldID.apiKey,
            WeaviateFieldID.skipTLSVerify
        ])
        #expect(!ids.contains("esAuthMethod"))
        #expect(!ids.contains("esApiKey"))
        let elasticsearch = try #require(
            PluginMetadataRegistry.shared.registryPluginDefaults().first { $0.typeId == "Elasticsearch" }
        )
        let esIds = elasticsearch.snapshot.connection.additionalConnectionFields.map(\.id)
        #expect(Set(ids).isDisjoint(with: Set(esIds)))
    }
}

@Suite("Weaviate connection fields")
struct WeaviateConnectionFieldsTests {
    private func fields() throws -> [ConnectionField] {
        let defaults = PluginMetadataRegistry.shared.registryPluginDefaults()
        let entry = try #require(defaults.first { $0.typeId == "Weaviate" })
        return entry.snapshot.connection.additionalConnectionFields
    }

    @Test("Auth method defaults to none")
    func authMethodDefaultsToNone() throws {
        let fields = try fields()
        let method = try #require(fields.first { $0.id == WeaviateFieldID.authMethod })
        #expect(method.defaultValue == "none")
        guard case .dropdown(let options) = method.fieldType else {
            Issue.record("Expected a dropdown field type")
            return
        }
        #expect(options.map(\.value) == ["none", "apiKey"])
    }

    @Test("The API key replaces both built-in credential rows")
    func apiKeyReplacesUsernameAndPassword() throws {
        let fields = try fields()
        let apiKey = try #require(fields.first { $0.id == WeaviateFieldID.apiKey })
        #expect(apiKey.isSecure)
        #expect(!apiKey.isRequired)
        #expect(apiKey.hidesPassword)
        #expect(fields.hidesPassword(forValues: [:]))
        #expect(fields.hidesUsername(forValues: [:]))
        #expect(fields.hidesPassword(forValues: [WeaviateFieldID.authMethod: "none"]))
        #expect(fields.hidesPassword(forValues: [WeaviateFieldID.authMethod: "apiKey"]))
        #expect(fields.hidesUsername(forValues: [WeaviateFieldID.authMethod: "none"]))
        #expect(fields.hidesUsername(forValues: [WeaviateFieldID.authMethod: "apiKey"]))
    }

    @Test("The snapshot hides the built-in password for every auth method")
    @MainActor
    func snapshotHidesBuiltInPassword() throws {
        let defaults = PluginMetadataRegistry.shared.registryPluginDefaults()
        let snapshot = try #require(defaults.first { $0.typeId == "Weaviate" }).snapshot
        #expect(snapshot.connection.hidesBuiltInPassword)
        for method in ["none", "apiKey"] {
            var connection = DatabaseConnection(name: "Weaviate", type: .weaviate)
            connection.additionalFields = [WeaviateFieldID.authMethod: method]
            #expect(PluginManager.shared.hidesPassword(for: connection), "\(method)")
        }
    }
}

@Suite("Weaviate field parity")
struct WeaviateFieldParityTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// The plugin's own field list replaces the registry snapshot the moment the plugin is
    /// installed, and no test can link both copies, so the two sources are compared as text.
    @Test("The plugin's field list matches the registry copy")
    func pluginCopyMatchesRegistryCopy() throws {
        let plugin = try source("Plugins/WeaviateDriverPlugin/WeaviatePlugin.swift")
        let registry = try source("TablePro/Core/Plugins/PluginMetadataRegistry+WeaviateDefaults.swift")
        for field in [WeaviateFieldID.authMethod, WeaviateFieldID.apiKey, WeaviateFieldID.skipTLSVerify] {
            #expect(registry.contains("id: \"\(field)\""), Comment(rawValue: field))
        }
        #expect(plugin.contains("id: WeaviateFieldID.authMethod"))
        #expect(plugin.contains("id: WeaviateFieldID.apiKey"))
        #expect(plugin.contains("id: WeaviateFieldID.skipTLSVerify"))
        for copy in [plugin, registry] {
            #expect(copy.contains("hidesPassword: true"))
            #expect(copy.contains("withHidesUsername(true)"))
            #expect(copy.contains("apiKey"))
        }
    }
}

@Suite("Weaviate plugin manifest")
struct WeaviatePluginManifestTests {
    @Test("Info.plist declares the current PluginKit ABI and the Weaviate type id")
    func plistDeclaresType() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Plugins/WeaviateDriverPlugin/Info.plist")
        let plist = try #require(NSDictionary(contentsOf: url) as? [String: Any])
        #expect(plist["TableProPluginKitVersion"] as? Int == PluginManager.currentPluginKitVersion)
        #expect(plist["TableProProvidesDatabaseTypeIds"] as? [String] == ["Weaviate"])
    }
}
