//
//  ConnectionStorageAIFieldsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ConnectionStorage AI Fields")
@MainActor
struct ConnectionStorageAIFieldsTests {
    private let storage: ConnectionStorage

    init() {
        let unique = UUID().uuidString
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("connections_\(unique).json")
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let defaultsName = "com.TablePro.tests.ConnectionStorage.AI.\(unique)"
        let syncName = "com.TablePro.tests.Sync.AI.\(unique)"
        guard let defaults = UserDefaults(suiteName: defaultsName),
              let syncDefaults = UserDefaults(suiteName: syncName) else {
            fatalError("UserDefaults suite creation failed in test setup")
        }
        let metadata = SyncMetadataStorage(userDefaults: syncDefaults)
        let tracker = SyncChangeTracker(metadataStorage: metadata)
        self.storage = ConnectionStorage(
            fileURL: fileURL,
            userDefaults: defaults,
            syncTracker: tracker
        )
    }

    @Test("round-trip preserves aiRules")
    func roundTripAIRules() {
        let id = UUID()
        let rules = "- Always filter by tenant_id\n- Avoid users.ssn"
        let connection = DatabaseConnection(
            id: id,
            name: "Test",
            type: .postgresql,
            aiRules: rules
        )

        storage.addConnection(connection)
        defer { storage.deleteConnection(connection) }

        let loaded = storage.loadConnections().first { $0.id == id }
        #expect(loaded?.aiRules == rules)
    }

    @Test("round-trip preserves nil aiRules")
    func roundTripNilAIRules() {
        let id = UUID()
        let connection = DatabaseConnection(id: id, name: "Test", type: .mysql)

        storage.addConnection(connection)
        defer { storage.deleteConnection(connection) }

        let loaded = storage.loadConnections().first { $0.id == id }
        #expect(loaded?.aiRules == nil)
    }

    @Test("round-trip preserves aiAlwaysAllowedTools")
    func roundTripAIAlwaysAllowedTools() {
        let id = UUID()
        let tools: Set<String> = ["execute_query", "list_tables"]
        let connection = DatabaseConnection(
            id: id,
            name: "Test",
            type: .mysql,
            aiAlwaysAllowedTools: tools
        )

        storage.addConnection(connection)
        defer { storage.deleteConnection(connection) }

        let loaded = storage.loadConnections().first { $0.id == id }
        #expect(loaded?.aiAlwaysAllowedTools == tools)
    }

    @Test("round-trip preserves empty aiAlwaysAllowedTools")
    func roundTripEmptyAIAlwaysAllowedTools() {
        let id = UUID()
        let connection = DatabaseConnection(id: id, name: "Test", type: .mysql)

        storage.addConnection(connection)
        defer { storage.deleteConnection(connection) }

        let loaded = storage.loadConnections().first { $0.id == id }
        #expect(loaded?.aiAlwaysAllowedTools.isEmpty == true)
    }

    @Test("aiRules survives mutate-and-update cycle")
    func updateAIRules() {
        let id = UUID()
        let connection = DatabaseConnection(
            id: id,
            name: "Test",
            type: .mysql,
            aiRules: "initial rules"
        )

        storage.addConnection(connection)
        defer { storage.deleteConnection(connection) }

        var updated = connection
        updated.aiRules = "updated rules"
        storage.updateConnection(updated)

        let loaded = storage.loadConnections().first { $0.id == id }
        #expect(loaded?.aiRules == "updated rules")
    }

    @Test("aiAlwaysAllowedTools survives mutate-and-update cycle")
    func updateAIAlwaysAllowedTools() {
        let id = UUID()
        let connection = DatabaseConnection(id: id, name: "Test", type: .mysql)

        storage.addConnection(connection)
        defer { storage.deleteConnection(connection) }

        var updated = connection
        updated.aiAlwaysAllowedTools = ["execute_query"]
        storage.updateConnection(updated)

        let loaded = storage.loadConnections().first { $0.id == id }
        #expect(loaded?.aiAlwaysAllowedTools == ["execute_query"])
    }
}
