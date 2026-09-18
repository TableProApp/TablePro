import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Spanner registry snapshot")
struct SpannerRegistrySnapshotTests {
    private func snapshot() throws -> PluginMetadataSnapshot {
        let defaults = PluginMetadataRegistry.shared.registryPluginDefaults()
        return try #require(defaults.first { $0.typeId == "Spanner" }).snapshot
    }

    private func field(_ id: String) throws -> ConnectionField {
        try #require(try snapshot().connection.additionalConnectionFields.first { $0.id == id })
    }

    @Test("Spanner is an API-only engine with no port and no built-in password")
    func connectionShape() throws {
        let snapshot = try snapshot()
        #expect(snapshot.connection.hidesBuiltInPassword)
        #expect(snapshot.connection.hidesBuiltInDatabase)
        #expect(snapshot.connectionMode == .apiOnly)
        #expect(snapshot.defaultPort == 0)
        #expect(snapshot.schema.containerEntityName == "Schema")
    }

    @Test("The nameless GoogleSQL default schema is presented as (default) and written unqualified")
    func defaultSchemaIsImplicit() throws {
        let schema = try snapshot().schema
        #expect(schema.defaultSchemaName == "(default)")
        #expect(schema.implicitSchemaName == "(default)")
        #expect(DatabaseType.spanner.implicitSchemaName == "(default)")
    }

    @Test("Every connection field keeps its id, in order")
    func fieldIds() throws {
        let ids = try snapshot().connection.additionalConnectionFields.map(\.id)
        #expect(ids == [
            "spAuthMethod",
            "spServiceAccountJson",
            "spProjectId",
            "spInstanceId",
            "spDatabaseId",
            "spOAuthClientId",
            "spOAuthClientSecret",
            "spOAuthRefreshToken",
            "spEndpoint"
        ])
    }

    @Test("The auth method offers the emulator beside the three Google credential sources")
    func authMethodOptions() throws {
        let authMethod = try field("spAuthMethod")
        #expect(authMethod.defaultValue == "serviceAccount")
        #expect(authMethod.fieldType == .dropdown(options: [
            .init(value: "serviceAccount", label: "Service Account Key"),
            .init(value: "adc", label: "Application Default Credentials"),
            .init(value: "oauth", label: "Google Account (OAuth)"),
            .init(value: "emulator", label: "Emulator (no credentials)")
        ]))
    }

    @Test("The OAuth refresh token is a secure field shown only for Google Account sign-in")
    func refreshTokenField() throws {
        let token = try field("spOAuthRefreshToken")
        #expect(token.isSecure)
        #expect(token.section == .authentication)
        #expect(token.visibleWhen == FieldVisibilityRule(fieldId: "spAuthMethod", values: ["oauth"]))
    }

    @Test("The endpoint defaults to production Spanner and sits in the advanced section")
    func endpointField() throws {
        let endpoint = try field("spEndpoint")
        #expect(endpoint.placeholder == "https://spanner.googleapis.com")
        #expect(endpoint.section == .advanced)
    }

    @Test("EXPLAIN renders its plan as indented text")
    func explainFormat() throws {
        let variants = try snapshot().explainVariants
        #expect(variants.map(\.sqlPrefix) == ["EXPLAIN"])
        #expect(variants.map(\.format) == [.indentedText])
    }

    @Test("Every auth method, the emulator included, keeps the built-in password hidden")
    @MainActor
    func passwordStaysHiddenForEveryAuthMethod() {
        for method in ["serviceAccount", "adc", "oauth", "emulator"] {
            var connection = DatabaseConnection(name: "Spanner", type: .spanner)
            connection.additionalFields = ["spAuthMethod": method]
            #expect(PluginManager.shared.hidesPassword(for: connection), "\(method)")
        }
    }
}
