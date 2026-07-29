//
//  ExternalDatabaseURLConnectTests.swift
//  TableProTests
//
//  Pins the fix for the drive-by SSRF / keychain-pollution finding: a password
//  carried by an externally delivered database URL must reach the driver as an
//  in-memory override and must never be written to the Keychain for a transient
//  connection. The open-URL flow is gated behind a confirmation alert and cannot
//  run deterministically in a unit test, so this exercises the override mechanism
//  the flow relies on.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("External database URL connect", .serialized)
@MainActor
struct ExternalDatabaseURLConnectTests {
    @Test("URL-supplied password reaches the driver in memory and is not persisted")
    func urlPasswordUsedInMemoryNotPersisted() async throws {
        let typeId = CapturingURLConnectPlugin.databaseTypeId
        PluginManager.shared.driverPlugins[typeId] = CapturingURLConnectPlugin()
        defer { PluginManager.shared.driverPlugins[typeId] = nil }

        let id = UUID()
        let connection = DatabaseConnection(
            id: id,
            name: "Transient URL",
            host: "db.example.com",
            port: 15_432,
            database: "app",
            username: "sa",
            type: DatabaseType(rawValue: typeId)
        )
        defer { ConnectionStorage.shared.deletePassword(for: id) }

        CapturingURLConnectPlugin.capturedPassword = nil
        _ = try await DatabaseDriverFactory.createDriver(
            for: connection,
            passwordOverride: "url-secret",
            awaitPlugins: true
        )

        #expect(CapturingURLConnectPlugin.capturedPassword == "url-secret")
        #expect(ConnectionStorage.shared.loadPassword(for: id) == nil)
    }
}

private final class CapturingURLConnectPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Capturing URL Connect Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Captures the resolved password for external URL connect tests"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "URLOverrideTestDB"
    static let databaseDisplayName = "URLOverrideTestDB"
    static let iconName = "database-icon"
    static let defaultPort = 15_432
    static let isDownloadable = false

    nonisolated(unsafe) static var capturedPassword: String?

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        Self.capturedPassword = config.password
        return FakeMSSQLPluginDriver()
    }

    override required init() {
        super.init()
    }
}
