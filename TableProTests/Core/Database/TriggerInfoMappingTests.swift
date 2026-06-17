//
//  TriggerInfoMappingTests.swift
//  TableProTests
//
//  Tests for PluginTriggerInfo encoding and the PluginDriverAdapter trigger bridge.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class StubTriggerDriver: PluginDatabaseDriver {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    var triggersToReturn: [PluginTriggerInfo] = []

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
    func fetchTriggers(table: String, schema: String?) async throws -> [PluginTriggerInfo] { triggersToReturn }
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

@Suite("Trigger info mapping")
struct TriggerInfoMappingTests {
    @Test("PluginTriggerInfo encodes and decodes")
    func codableRoundTrip() throws {
        let original = PluginTriggerInfo(
            name: "trg_audit",
            timing: "AFTER",
            event: "INSERT",
            statement: "CREATE TRIGGER trg_audit AFTER INSERT ON t FOR EACH ROW BEGIN END"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PluginTriggerInfo.self, from: data)
        #expect(decoded.name == original.name)
        #expect(decoded.timing == original.timing)
        #expect(decoded.event == original.event)
        #expect(decoded.statement == original.statement)
    }

    @Test("Adapter maps plugin triggers to app TriggerInfo preserving fields")
    func adapterMapsTriggers() async throws {
        let driver = StubTriggerDriver()
        driver.triggersToReturn = [
            PluginTriggerInfo(
                name: "trg_audit",
                timing: "AFTER",
                event: "INSERT OR UPDATE",
                statement: "CREATE TRIGGER trg_audit ...",
                enabled: false
            )
        ]
        let connection = DatabaseConnection(name: "Test", type: .postgresql)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: driver)

        let triggers = try await adapter.fetchTriggers(table: "t")
        #expect(triggers.count == 1)
        let trigger = try #require(triggers.first)
        #expect(trigger.name == "trg_audit")
        #expect(trigger.timing == "AFTER")
        #expect(trigger.event == "INSERT OR UPDATE")
        #expect(trigger.statement == "CREATE TRIGGER trg_audit ...")
        #expect(trigger.enabled == false)
    }

    @Test("PluginTriggerInfo carries enabled state through Codable")
    func codableRoundTripWithEnabled() throws {
        let original = PluginTriggerInfo(
            name: "trg_check",
            timing: "BEFORE",
            event: "UPDATE",
            statement: "CREATE TRIGGER trg_check ...",
            enabled: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PluginTriggerInfo.self, from: data)
        #expect(decoded.enabled == true)
    }
}

@Suite("StructureTab triggers")
struct StructureTabTriggersTests {
    @Test("Triggers tab is part of the canonical tab set")
    func triggersInAllCases() {
        #expect(StructureTab.allCases.contains(.triggers))
    }

    @Test("Triggers tab has a localized display name")
    func triggersDisplayName() {
        #expect(StructureTab.triggers.displayName == "Triggers")
    }
}
