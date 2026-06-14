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

    @Test("Defaults to an empty selection")
    func defaultsEmpty() throws {
        let storage = try makeStorage()
        #expect(storage.selectedDatabases(connectionId: UUID()).isEmpty)
    }

    @Test("Selected databases round-trip")
    func selectedRoundTrip() throws {
        let storage = try makeStorage()
        let connId = UUID()
        storage.setSelectedDatabases(Set(["db1", "db2"]), connectionId: connId)
        #expect(storage.selectedDatabases(connectionId: connId) == Set(["db1", "db2"]))
    }

    @Test("Setting an empty selection clears the stored value")
    func emptySelectionClears() throws {
        let storage = try makeStorage()
        let connId = UUID()
        storage.setSelectedDatabases(Set(["db1"]), connectionId: connId)
        storage.setSelectedDatabases([], connectionId: connId)
        #expect(storage.selectedDatabases(connectionId: connId).isEmpty)
    }

    @Test("Selection is isolated per connection")
    func perConnectionIsolation() throws {
        let storage = try makeStorage()
        let a = UUID()
        let b = UUID()
        storage.setSelectedDatabases(Set(["x"]), connectionId: a)
        #expect(storage.selectedDatabases(connectionId: b).isEmpty)
        #expect(storage.selectedDatabases(connectionId: a) == Set(["x"]))
    }

    @Test("Remove filter clears the selection")
    func removeClears() throws {
        let storage = try makeStorage()
        let connId = UUID()
        storage.setSelectedDatabases(Set(["db1"]), connectionId: connId)
        storage.removeFilter(for: connId)
        #expect(storage.selectedDatabases(connectionId: connId).isEmpty)
    }

    @Test("Remove filters batch clears across connections")
    func removeBatchClears() throws {
        let storage = try makeStorage()
        let a = UUID()
        let b = UUID()
        storage.setSelectedDatabases(Set(["db1"]), connectionId: a)
        storage.setSelectedDatabases(Set(["db2"]), connectionId: b)
        storage.removeFilters(for: Set([a, b]))
        #expect(storage.selectedDatabases(connectionId: a).isEmpty)
        #expect(storage.selectedDatabases(connectionId: b).isEmpty)
    }
}
