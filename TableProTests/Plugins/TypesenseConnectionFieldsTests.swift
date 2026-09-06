//
//  TypesenseConnectionFieldsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

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
