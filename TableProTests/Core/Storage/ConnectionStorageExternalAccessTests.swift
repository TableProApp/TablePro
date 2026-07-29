//
//  ConnectionStorageExternalAccessTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("ConnectionStorage External Access")
@MainActor
struct ConnectionStorageExternalAccessTests {
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
        let defaultsName = "com.TablePro.tests.ConnectionStorage.ExternalAccess.\(unique)"
        let syncName = "com.TablePro.tests.Sync.ExternalAccess.\(unique)"
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

    @Test("round-trip preserves external access", arguments: ExternalAccessLevel.allCases)
    func roundTripExternalAccess(_ level: ExternalAccessLevel) {
        let id = UUID()
        let connection = DatabaseConnection(
            id: id,
            name: "Test",
            type: .postgresql,
            externalAccess: level
        )

        storage.addConnection(connection)
        defer { storage.deleteConnection(connection) }

        let loaded = storage.loadConnections().first { $0.id == id }
        #expect(loaded?.externalAccess == level)
    }

    @Test("external access survives mutate-and-update cycle")
    func updateExternalAccess() {
        let id = UUID()
        let connection = DatabaseConnection(
            id: id,
            name: "Test",
            type: .mysql,
            externalAccess: .readOnly
        )

        storage.addConnection(connection)
        defer { storage.deleteConnection(connection) }

        var updated = connection
        updated.externalAccess = .readWrite
        storage.updateConnection(updated)

        let loaded = storage.loadConnections().first { $0.id == id }
        #expect(loaded?.externalAccess == .readWrite)
    }

    @Test("legacy records without externalAccess default to readOnly")
    func legacyDecodeDefaultsToReadOnly() throws {
        let stored = try JSONDecoder().decode(
            StoredConnection.self,
            from: Data(Self.legacyJSONWithoutExternalAccess.utf8)
        )
        #expect(stored.toConnection().externalAccess == .readOnly)
    }

    private static let legacyJSONWithoutExternalAccess = """
    {
        "id": "11111111-2222-3333-4444-555555555555",
        "name": "Legacy",
        "host": "localhost",
        "port": 3306,
        "database": "test",
        "username": "root",
        "type": "MySQL",
        "sshEnabled": false,
        "sshHost": "",
        "sshUsername": "",
        "sshAuthMethod": "password",
        "sshPrivateKeyPath": "",
        "sshAgentSocketPath": "",
        "sslMode": "disabled",
        "sslCaCertificatePath": "",
        "sslClientCertificatePath": "",
        "sslClientKeyPath": "",
        "color": "None",
        "safeModeLevel": "silent",
        "sortOrder": 0,
        "localOnly": false,
        "isSample": false,
        "isFavorite": false,
        "totpMode": "none",
        "totpAlgorithm": "sha1",
        "totpDigits": 6,
        "totpPeriod": 30
    }
    """
}
