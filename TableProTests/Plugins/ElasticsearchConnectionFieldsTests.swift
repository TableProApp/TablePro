//
//  ElasticsearchConnectionFieldsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Elasticsearch connection fields")
struct ElasticsearchConnectionFieldsTests {
    private func elasticsearchFields() throws -> [ConnectionField] {
        let defaults = PluginMetadataRegistry.shared.registryPluginDefaults()
        let entry = try #require(defaults.first { $0.typeId == "Elasticsearch" })
        return entry.snapshot.connection.additionalConnectionFields
    }

    @Test("Registry declares auth method, API key, and TLS fields")
    func registryDeclaresAllFields() throws {
        let fields = try elasticsearchFields()
        #expect(fields.map(\.id) == ["esAuthMethod", "esApiKey", "esSkipTLSVerify"])
    }

    @Test("Auth method dropdown defaults to basic and offers API key and none")
    func authMethodDropdownDefaultsToBasic() throws {
        let fields = try elasticsearchFields()
        let method = try #require(fields.first { $0.id == "esAuthMethod" })
        #expect(method.defaultValue == "basic")
        guard case .dropdown(let options) = method.fieldType else {
            Issue.record("Expected a dropdown field type")
            return
        }
        #expect(options.map(\.value) == ["basic", "apiKey", "none"])
    }

    @Test("Auth method dropdown drives password hiding, API key field does not")
    func authMethodDropdownControlsPasswordHiding() throws {
        let fields = try elasticsearchFields()
        let method = try #require(fields.first { $0.id == "esAuthMethod" })
        let apiKey = try #require(fields.first { $0.id == "esApiKey" })
        #expect(method.hidesPassword)
        #expect(!apiKey.hidesPassword)
    }

    @Test("API key is a secure field gated to API key mode")
    func apiKeyIsSecureAndModeGated() throws {
        let fields = try elasticsearchFields()
        let apiKey = try #require(fields.first { $0.id == "esApiKey" })
        #expect(apiKey.isSecure)
        #expect(apiKey.visibleWhen == FieldVisibilityRule(fieldId: "esAuthMethod", values: ["apiKey"]))
    }

    @Test("Password row shows for Username & Password and hides for API key and None")
    func passwordShowsOnlyForBasicAuth() throws {
        let fields = try elasticsearchFields()
        #expect(!fields.hidesPassword(forValues: [:]))
        #expect(!fields.hidesPassword(forValues: ["esAuthMethod": "basic"]))
        #expect(fields.hidesPassword(forValues: ["esAuthMethod": "apiKey"]))
        #expect(fields.hidesPassword(forValues: ["esAuthMethod": "none"]))
    }

    @Test("API key field visibility swaps with the auth method")
    @MainActor
    func apiKeyVisibilitySwapsByAuthMethod() throws {
        let type = DatabaseType(rawValue: "Elasticsearch")
        let fields = try elasticsearchFields()
        let apiKey = try #require(fields.first { $0.id == "esApiKey" })
        #expect(!PluginFieldRendering.isFieldVisible(apiKey, type: type, values: ["esAuthMethod": "basic"]))
        #expect(PluginFieldRendering.isFieldVisible(apiKey, type: type, values: ["esAuthMethod": "apiKey"]))
        #expect(!PluginFieldRendering.isFieldVisible(apiKey, type: type, values: ["esAuthMethod": "none"]))
    }
}
