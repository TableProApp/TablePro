import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite("DatabaseTreeFilterStorage")
struct DatabaseTreeFilterStorageTests {
    private func makeStorage() throws -> DatabaseTreeFilterStorage {
        let suite = "DatabaseTreeFilterStorageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return DatabaseTreeFilterStorage(defaults: defaults)
    }

    @Test("Defaults to disabled with empty selection")
    func defaultsDisabledEmpty() throws {
        let storage = try makeStorage()
        let connId = UUID()
        #expect(storage.isEnabled(connectionId: connId) == false)
        #expect(storage.selectedDatabases(connectionId: connId).isEmpty)
    }

    @Test("Enable toggle persists")
    func enablePersists() throws {
        let storage = try makeStorage()
        let connId = UUID()
        storage.setEnabled(true, connectionId: connId)
        #expect(storage.isEnabled(connectionId: connId))
        storage.setEnabled(false, connectionId: connId)
        #expect(!storage.isEnabled(connectionId: connId))
    }

    @Test("Selected databases round-trip")
    func selectedRoundTrip() throws {
        let storage = try makeStorage()
        let connId = UUID()
        storage.setSelectedDatabases(Set(["db1", "db2"]), connectionId: connId)
        #expect(storage.selectedDatabases(connectionId: connId) == Set(["db1", "db2"]))
    }

    @Test("State is isolated per connection")
    func perConnectionIsolation() throws {
        let storage = try makeStorage()
        let a = UUID()
        let b = UUID()
        storage.setEnabled(true, connectionId: a)
        storage.setSelectedDatabases(Set(["x"]), connectionId: a)
        #expect(!storage.isEnabled(connectionId: b))
        #expect(storage.selectedDatabases(connectionId: b).isEmpty)
    }

    @Test("Remove filter clears both fields")
    func removeClearsBoth() throws {
        let storage = try makeStorage()
        let connId = UUID()
        storage.setEnabled(true, connectionId: connId)
        storage.setSelectedDatabases(Set(["db1"]), connectionId: connId)
        storage.removeFilter(for: connId)
        #expect(!storage.isEnabled(connectionId: connId))
        #expect(storage.selectedDatabases(connectionId: connId).isEmpty)
    }

    @Test("Remove filters batch clears across connections")
    func removeBatchClears() throws {
        let storage = try makeStorage()
        let a = UUID()
        let b = UUID()
        storage.setEnabled(true, connectionId: a)
        storage.setSelectedDatabases(Set(["db1"]), connectionId: a)
        storage.setEnabled(true, connectionId: b)
        storage.setSelectedDatabases(Set(["db2"]), connectionId: b)
        storage.removeFilters(for: Set([a, b]))
        #expect(!storage.isEnabled(connectionId: a))
        #expect(!storage.isEnabled(connectionId: b))
        #expect(storage.selectedDatabases(connectionId: a).isEmpty)
        #expect(storage.selectedDatabases(connectionId: b).isEmpty)
    }
}
