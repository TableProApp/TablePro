//
//  PluginRowLocatorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class LocatingDriver: PluginDatabaseDriver, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func connect() async throws {}
    func disconnect() {}

    func execute(query: String) async throws -> PluginQueryResult {
        var result = PluginQueryResult(
            columns: ["_id"],
            columnTypeNames: ["Int32"],
            rows: [["1"], ["2"]],
            rowsAffected: 0,
            timing: PluginQueryTiming(total: 0)
        )
        result.rowLocators = [#"{"$numberInt":"1"}"#, nil]
        return result
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

struct PluginRowLocatorTests {
    private let locators: [String?] = [#"{"$numberInt":"1"}"#, nil]

    private func makeAdapter() -> PluginDriverAdapter {
        PluginDriverAdapter(connection: DatabaseConnection(name: "Test", type: .mongodb), pluginDriver: LocatingDriver())
    }

    @Test("A driver's row locators reach the query result and the fetch result unchanged")
    func locatorsFlowToTheFetchResult() async throws {
        let adapter = makeAdapter()
        let result = try await adapter.executeUserQuery(query: "db.c.find({})", rowCap: nil, parameters: nil)
        #expect(result.rowLocators == locators)
        let fetched = try await QueryExecutor.fetchQueryData(driver: adapter, sql: "db.c.find({})", rowCap: nil)
        #expect(fetched.rowLocators == locators)
    }

    @Test("A driver built before documents could be fetched refuses rather than answering")
    func defaultFetchDocumentRefuses() async {
        await #expect(throws: PluginDriverUnsupportedOperation.writeDocument) {
            try await makeAdapter().fetchDocument(table: "c", schema: nil, locator: "1")
        }
    }

    @Test("Row locators survive the result's own coding, and a payload without them decodes")
    func coding() throws {
        var result = PluginQueryResult(
            columns: ["_id"], columnTypeNames: ["Int32"], rows: [["1"], ["2"]], rowsAffected: 0,
            timing: PluginQueryTiming(total: 0)
        )
        result.rowLocators = locators
        let decoded = try JSONDecoder().decode(PluginQueryResult.self, from: JSONEncoder().encode(result))
        #expect(decoded.rowLocators == locators)

        var legacy = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(PluginQueryResult.empty)) as? [String: Any]
        )
        legacy.removeValue(forKey: "rowLocators")
        let decodedLegacy = try JSONDecoder().decode(
            PluginQueryResult.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        #expect(decodedLegacy.rowLocators == nil)
    }
}
