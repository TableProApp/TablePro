import Foundation
import TableProPluginKit
import Testing

private final class StubServerObjectDriver: PluginDatabaseDriver, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}
    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }

    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

struct PluginServerObjectDefaultsTests {
    @Test("A driver that implements nothing declares no kinds and lists no objects")
    func defaultsDeclareNothing() async throws {
        let driver = StubServerObjectDriver()
        #expect(driver.serverObjectKinds.isEmpty)
        #expect(try await driver.fetchServerObjects(ofKind: "event", schema: "app").isEmpty)
        #expect(try await driver.fetchServerObjects(ofKind: "extension", schema: nil).isEmpty)
    }

    @Test("Reading an object again returns it when the listing carried its definition")
    func rereadKeepsListedDefinition() async throws {
        let listed = PluginServerObjectInfo(kindId: "event", name: "nightly", definition: "CREATE EVENT nightly")
        let read = try await StubServerObjectDriver().fetchServerObject(listed)
        #expect(read.name == "nightly")
        #expect(read.definition == "CREATE EVENT nightly")
    }

    @Test("Reading an object again without a definition is unsupported, not missing")
    func rereadWithoutDefinitionIsUnsupported() async {
        let listed = PluginServerObjectInfo(kindId: "event", name: "nightly", definition: "")
        var refusal: Error?
        do {
            _ = try await StubServerObjectDriver().fetchServerObject(listed)
        } catch {
            refusal = error
        }
        guard let sourceError = refusal as? PluginObjectSourceError, case .unsupported(let name) = sourceError else {
            Issue.record("expected unsupported, got \(String(describing: refusal))")
            return
        }
        #expect(name == "nightly")
    }

    @Test("A kind is listed per container unless it says otherwise")
    func kindScopeDefaultsToContainer() {
        let kind = PluginServerObjectKind(id: "event", displayName: "Event", pluralDisplayName: "Events", iconName: "calendar")
        #expect(kind.scope == .container)
    }

    @Test("Kinds and objects round-trip through Codable")
    func codableRoundTrip() throws {
        let kind = PluginServerObjectKind(
            id: "extension", displayName: "Extension", pluralDisplayName: "Extensions",
            iconName: "puzzlepiece.extension", scope: .database
        )
        let decodedKind = try JSONDecoder().decode(PluginServerObjectKind.self, from: JSONEncoder().encode(kind))
        #expect(decodedKind == kind)

        let object = PluginServerObjectInfo(
            kindId: "extension", name: "pgcrypto", schema: "public", identity: "16384", detail: "1.3",
            isEnabled: true, definition: "CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;",
            attributes: [PluginObjectAttribute(label: "Version", value: "1.3")]
        )
        let decoded = try JSONDecoder().decode(PluginServerObjectInfo.self, from: JSONEncoder().encode(object))
        #expect(decoded.kindId == object.kindId)
        #expect(decoded.name == object.name)
        #expect(decoded.schema == object.schema)
        #expect(decoded.identity == object.identity)
        #expect(decoded.detail == object.detail)
        #expect(decoded.isEnabled == object.isEnabled)
        #expect(decoded.definition == object.definition)
        #expect(decoded.attributes == object.attributes)
    }
}
