//
//  TypesenseConnectionFieldsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

/// The bundle manifest, read from the repository rather than from a loaded bundle.
///
/// `PluginManifest` reads `TableProProvidesDatabaseTypeIds` from a plugin's Info.plist without
/// loading its code, and `isDriverInstalled` answers from that. Without the key the driver is
/// eagerly loaded (which the app logs as "declared no TableProProvides* capability keys ...;
/// eager loading will block startup") and its type never reaches `lazyDriverURLs`, so picking
/// Typesense in the connection form offers to download a plugin that is already installed.
@Suite("Typesense plugin manifest")
struct TypesensePluginManifestTests {
    private static let infoPlist: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 3 {
            url.deleteLastPathComponent()
        }
        return url
            .appendingPathComponent("Plugins/TypesenseDriverPlugin/Info.plist")
    }()

    private func manifest() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.infoPlist)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return (plist as? [String: Any]) ?? [:]
    }

    @Test("The bundle declares the database type it provides, so the app can register it lazily")
    func declaresProvidedDatabaseTypeIds() throws {
        let plist = try manifest()
        let ids = try #require(plist["TableProProvidesDatabaseTypeIds"] as? [String])
        #expect(ids == ["Typesense"])
    }

    /// The id in the manifest is what `isDriverInstalled` looks up, so it has to be the same
    /// string the registry snapshot and `DatabaseType.typesense` use.
    @Test("The declared id matches the registered database type")
    @MainActor
    func declaredIdMatchesTheRegisteredType() throws {
        let plist = try manifest()
        let ids = try #require(plist["TableProProvidesDatabaseTypeIds"] as? [String])
        #expect(ids.contains(DatabaseType.typesense.rawValue))
        let defaults = PluginMetadataRegistry.shared.registryPluginDefaults()
        #expect(defaults.contains { $0.typeId == DatabaseType.typesense.rawValue })
    }

    @Test("The bundle pins the PluginKit ABI and the release it ships in")
    func declaresVersionGates() throws {
        let plist = try manifest()
        #expect(plist["TableProPluginKitVersion"] as? Int == 21)
        #expect(plist["TableProMinAppVersion"] as? String == "0.73.0")
    }
}

@Suite("Typesense connection fields")
struct TypesenseConnectionFieldsTests {
    private func typesenseFields() throws -> [ConnectionField] {
        let defaults = PluginMetadataRegistry.shared.registryPluginDefaults()
        let entry = try #require(defaults.first { $0.typeId == "Typesense" })
        return entry.snapshot.connection.additionalConnectionFields
    }

    @Test("Registry declares the API key and the TLS toggle")
    func registryDeclaresAllFields() throws {
        let fields = try typesenseFields()
        #expect(fields.map(\.id) == ["typesenseApiKey", "typesenseSkipTLSVerify"])
    }

    @Test("The API key is a required secure field in the authentication section")
    func apiKeyIsRequiredAndSecure() throws {
        let fields = try typesenseFields()
        let apiKey = try #require(fields.first { $0.id == "typesenseApiKey" })
        #expect(apiKey.isSecure)
        #expect(apiKey.isRequired)
        #expect(apiKey.section == .authentication)
        #expect(apiKey.visibleWhen == nil)
    }

    /// Typesense has no user accounts, so leaving Username and Password on the form would ask for
    /// two credentials the server never reads.
    @Test("The API key replaces both built-in credential rows")
    func apiKeyReplacesUsernameAndPassword() throws {
        let fields = try typesenseFields()
        #expect(fields.hidesPassword(forValues: [:]))
        #expect(fields.hidesUsername(forValues: [:]))
    }

    @Test("A secure connection field is stored in the Keychain, not the connection file")
    @MainActor
    func apiKeyIsTreatedAsSecureStorage() throws {
        let secureIds = PluginManager.shared.secureConnectionFieldIds(for: DatabaseType.typesense)
        #expect(secureIds.contains("typesenseApiKey"))
        #expect(!secureIds.contains("typesenseSkipTLSVerify"))
    }

    @Test("The TLS toggle sits in the advanced section and defaults to off")
    func tlsToggleDefaultsOff() throws {
        let fields = try typesenseFields()
        let toggle = try #require(fields.first { $0.id == "typesenseSkipTLSVerify" })
        #expect(toggle.section == .advanced)
        #expect(toggle.defaultValue == "false")
        if case .toggle = toggle.fieldType {} else {
            Issue.record("Expected a toggle field type")
        }
    }

    @Test("The snapshot describes a container-only engine on the Typesense default port")
    func snapshotDescribesTheEngine() throws {
        let defaults = PluginMetadataRegistry.shared.registryPluginDefaults()
        let entry = try #require(defaults.first { $0.typeId == "Typesense" })
        let snapshot = entry.snapshot
        #expect(snapshot.defaultPort == 8_108)
        #expect(snapshot.connection.hidesBuiltInDatabase)
        #expect(!snapshot.supportsDatabaseSwitching)
        #expect(snapshot.schema.tableEntityName == "Collections")
        #expect(snapshot.schema.defaultPrimaryKeyColumn == "id")
        #expect(snapshot.schema.immutableColumns == ["id"])
    }
}
