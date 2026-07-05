//
//  FilterSettingsStorageTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("FilterSettingsStorage")
@MainActor
struct FilterSettingsStorageTests {
    private func makeStorage() -> (storage: FilterSettingsStorage, directory: URL) {
        let suiteName = "FilterSettingsStorageTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create UserDefaults suite for tests")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilterSettingsStorageTests-\(UUID().uuidString)", isDirectory: true)
        return (FilterSettingsStorage(filterStateDirectory: directory, defaults: defaults), directory)
    }

    @Test("Saving then loading round-trips the filters")
    func roundTripsSaveAndLoad() {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionId = UUID()
        let filters = [TestFixtures.makeTableFilter(column: "email", value: "a@b.com")]

        storage.saveLastFilters(filters, for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil)

        #expect(
            storage.loadLastFilters(for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil) == filters
        )
    }

    @Test("Loading an unsaved table returns no filters")
    func loadReturnsEmptyForMissing() {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(
            storage.loadLastFilters(for: "users", connectionId: UUID(), databaseName: "db", schemaName: nil).isEmpty
        )
    }

    @Test("The same table name in different connections stays isolated")
    func connectionsAreIsolated() {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionA = UUID()
        let connectionB = UUID()
        let filtersA = [TestFixtures.makeTableFilter(column: "a")]

        storage.saveLastFilters(filtersA, for: "users", connectionId: connectionA, databaseName: "db", schemaName: nil)

        #expect(
            storage.loadLastFilters(for: "users", connectionId: connectionB, databaseName: "db", schemaName: nil).isEmpty
        )
        #expect(
            storage.loadLastFilters(for: "users", connectionId: connectionA, databaseName: "db", schemaName: nil) == filtersA
        )
    }

    @Test("The same table name in different databases stays isolated")
    func databasesAreIsolated() {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionId = UUID()
        let filters = [TestFixtures.makeTableFilter(column: "a")]

        storage.saveLastFilters(filters, for: "users", connectionId: connectionId, databaseName: "db_a", schemaName: nil)

        #expect(
            storage.loadLastFilters(for: "users", connectionId: connectionId, databaseName: "db_b", schemaName: nil).isEmpty
        )
    }

    @Test("The same table name in different schemas stays isolated")
    func schemasAreIsolated() {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionId = UUID()
        let filters = [TestFixtures.makeTableFilter(column: "a")]

        storage.saveLastFilters(filters, for: "users", connectionId: connectionId, databaseName: "db", schemaName: "public")

        #expect(
            storage.loadLastFilters(for: "users", connectionId: connectionId, databaseName: "db", schemaName: "app").isEmpty
        )
        #expect(
            storage.loadLastFilters(for: "users", connectionId: connectionId, databaseName: "db", schemaName: "public") == filters
        )
    }

    @Test("Removing a connection's filters keeps other connections intact")
    func removeFiltersForConnection() {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let deletedConnection = UUID()
        let keptConnection = UUID()
        let deletedFilters = [TestFixtures.makeTableFilter(column: "a")]
        let keptFilters = [TestFixtures.makeTableFilter(column: "b")]

        storage.saveLastFilters(
            deletedFilters, for: "users", connectionId: deletedConnection, databaseName: "db", schemaName: nil
        )
        storage.saveLastFilters(
            keptFilters, for: "users", connectionId: keptConnection, databaseName: "db", schemaName: nil
        )

        storage.removeFilters(for: deletedConnection)
        storage.waitForPendingDiskWrites()

        #expect(
            storage.loadLastFilters(for: "users", connectionId: deletedConnection, databaseName: "db", schemaName: nil)
                .isEmpty
        )
        #expect(
            storage.loadLastFilters(for: "users", connectionId: keptConnection, databaseName: "db", schemaName: nil)
                == keptFilters
        )
    }

    @Test("Batch removal clears filters for every given connection in one pass")
    func removeFiltersForMultipleConnections() {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = UUID()
        let second = UUID()
        let kept = UUID()
        for connectionId in [first, second, kept] {
            storage.saveLastFilters(
                [TestFixtures.makeTableFilter(column: "a")],
                for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil
            )
        }

        storage.removeFilters(for: [first, second])
        storage.waitForPendingDiskWrites()

        #expect(storage.loadLastFilters(for: "users", connectionId: first, databaseName: "db", schemaName: nil).isEmpty)
        #expect(storage.loadLastFilters(for: "users", connectionId: second, databaseName: "db", schemaName: nil).isEmpty)
        #expect(
            !storage.loadLastFilters(for: "users", connectionId: kept, databaseName: "db", schemaName: nil).isEmpty
        )
    }

    @Test("Removed filters stay gone for a fresh storage instance")
    func removeFiltersDeletesFiles() {
        let suiteName = "FilterSettingsStorageTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create UserDefaults suite for tests")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilterSettingsStorageTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionId = UUID()
        let storage = FilterSettingsStorage(filterStateDirectory: directory, defaults: defaults)
        storage.saveLastFilters(
            [TestFixtures.makeTableFilter(column: "a")],
            for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil
        )

        storage.removeFilters(for: connectionId)
        storage.waitForPendingDiskWrites()

        let fresh = FilterSettingsStorage(filterStateDirectory: directory, defaults: defaults)
        #expect(
            fresh.loadLastFilters(for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil).isEmpty
        )
    }

    @Test("Saving an empty filter set clears the stored filters")
    func savingEmptyClearsState() {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionId = UUID()
        storage.saveLastFilters(
            [TestFixtures.makeTableFilter()], for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil
        )
        storage.saveLastFilters([], for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil)
        storage.waitForPendingDiskWrites()

        #expect(
            storage.loadLastFilters(for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil).isEmpty
        )
    }

    @Test("New installs default to restoring the last filter")
    func defaultPanelStateRestoresLast() {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(storage.loadSettings().panelState == .restoreLast)
    }

    @Test("Migration upgrades a stored Always Hide setting to Restore Last")
    func migrationUpgradesAlwaysHide() throws {
        let suiteName = "FilterSettingsStorageTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilterSettingsStorageTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let stored = FilterSettings(panelState: .alwaysHide)
        defaults.set(try JSONEncoder().encode(stored), forKey: "com.TablePro.filter.settings")

        let storage = FilterSettingsStorage(filterStateDirectory: directory, defaults: defaults)

        #expect(storage.loadSettings().panelState == .restoreLast)
    }

    @Test("Saved filters decode from disk in a fresh storage instance")
    func persistsAcrossInstances() {
        let suiteName = "FilterSettingsStorageTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create UserDefaults suite for tests")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilterSettingsStorageTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionId = UUID()
        let filters = [TestFixtures.makeTableFilter(column: "email", value: "a@b.com")]

        let writer = FilterSettingsStorage(filterStateDirectory: directory, defaults: defaults)
        writer.saveLastFilters(filters, for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil)
        writer.waitForPendingDiskWrites()

        let reader = FilterSettingsStorage(filterStateDirectory: directory, defaults: defaults)
        #expect(
            reader.loadLastFilters(for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil) == filters
        )
    }

    @Test("Clearing removes the stored filters so a reopen restores nothing")
    func clearRemovesStoredFilters() {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionId = UUID()
        let filters = [TestFixtures.makeTableFilter(column: "email", value: "a@b.com")]

        storage.saveLastFilters(filters, for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil)
        storage.clearLastFilters(for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil)
        storage.waitForPendingDiskWrites()

        #expect(
            storage.loadLastFilters(for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil).isEmpty
        )
    }

    @Test("A save followed by an immediate clear leaves no file on disk")
    func clearAfterSaveLeavesNothingOnDisk() {
        let suiteName = "FilterSettingsStorageTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create UserDefaults suite for tests")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilterSettingsStorageTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionId = UUID()
        let filters = [TestFixtures.makeTableFilter(column: "email", value: "a@b.com")]

        let writer = FilterSettingsStorage(filterStateDirectory: directory, defaults: defaults)
        writer.saveLastFilters(filters, for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil)
        writer.clearLastFilters(for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil)
        writer.waitForPendingDiskWrites()

        let reader = FilterSettingsStorage(filterStateDirectory: directory, defaults: defaults)
        #expect(
            reader.loadLastFilters(for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil).isEmpty
        )
    }

    @Test("Browse search persists to disk and clearing it leaves nothing")
    func browseSearchPersistsAndClears() {
        let suiteName = "FilterSettingsStorageTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create UserDefaults suite for tests")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilterSettingsStorageTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionId = UUID()
        let state = BrowseSearchState(pattern: "user:*", typeScope: "hash")

        let writer = FilterSettingsStorage(filterStateDirectory: directory, defaults: defaults)
        writer.saveBrowseSearch(state, for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil)
        writer.waitForPendingDiskWrites()

        let reader = FilterSettingsStorage(filterStateDirectory: directory, defaults: defaults)
        #expect(
            reader.loadBrowseSearch(for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil) == state
        )

        writer.saveBrowseSearch(
            BrowseSearchState(), for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil
        )
        writer.waitForPendingDiskWrites()

        let afterClear = FilterSettingsStorage(filterStateDirectory: directory, defaults: defaults)
        #expect(
            !afterClear.loadBrowseSearch(for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil)
                .isActive
        )
    }
}
