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

    @Test("Dropping a table forgets its filters and its browse search")
    func dropTableForgetsFiltersAndBrowseSearch() {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionId = UUID()
        let filters = [TestFixtures.makeTableFilter(column: "email", value: "a@b.com")]
        storage.saveLastFilters(
            PersistedFilterState(filters: filters),
            for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil
        )
        storage.saveBrowseSearch(
            BrowseSearchState(pattern: "user:*"),
            for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil
        )

        storage.dropTable(TableScope(connectionId: connectionId, database: "db", schema: nil, table: "users"))
        storage.waitForPendingDiskWrites()

        #expect(
            storage.loadLastFilters(for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil)
                .isEmpty
        )
        #expect(
            !storage.loadBrowseSearch(for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil)
                .isActive
        )
    }

    @Test("Dropping a table leaves its siblings alone")
    func dropTableLeavesSiblingsAlone() {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionId = UUID()
        let filters = [TestFixtures.makeTableFilter(column: "email", value: "a@b.com")]
        for table in ["users", "orders"] {
            storage.saveLastFilters(
                PersistedFilterState(filters: filters),
                for: table, connectionId: connectionId, databaseName: "db", schemaName: nil
            )
        }

        storage.dropTable(TableScope(connectionId: connectionId, database: "db", schema: nil, table: "users"))
        storage.waitForPendingDiskWrites()

        #expect(
            storage.loadLastFilters(for: "orders", connectionId: connectionId, databaseName: "db", schemaName: nil)
                == filters
        )
    }

    /// The table list is lazy, so a table nobody opened this session is exactly the case a
    /// per-table sweep would miss. A fresh reader proves the file went, not just the cache.
    @Test("Dropping a schema forgets a table this session never loaded")
    func dropContainerForgetsAnUnloadedTable() throws {
        let defaults = try #require(UserDefaults(suiteName: "FilterSettingsStorageTests-\(UUID().uuidString)"))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilterSettingsStorageTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionId = UUID()
        let filters = [TestFixtures.makeTableFilter(column: "email", value: "a@b.com")]

        let writer = FilterSettingsStorage(filterStateDirectory: directory, defaults: defaults)
        writer.saveLastFilters(
            PersistedFilterState(filters: filters),
            for: "users", connectionId: connectionId, databaseName: "db", schemaName: "public"
        )
        writer.saveLastFilters(
            PersistedFilterState(filters: filters),
            for: "orders", connectionId: connectionId, databaseName: "db", schemaName: "billing"
        )
        writer.waitForPendingDiskWrites()

        let dropper = FilterSettingsStorage(filterStateDirectory: directory, defaults: defaults)
        dropper.dropContainer(connectionId: connectionId, database: "db", schema: "public")
        dropper.waitForPendingDiskWrites()

        let reader = FilterSettingsStorage(filterStateDirectory: directory, defaults: defaults)
        #expect(
            reader.loadLastFilters(for: "users", connectionId: connectionId, databaseName: "db", schemaName: "public")
                .isEmpty
        )
        #expect(
            reader.loadLastFilters(for: "orders", connectionId: connectionId, databaseName: "db", schemaName: "billing")
                == filters
        )
    }

    @Test("Dropping a database forgets every schema under it")
    func dropContainerWithoutSchemaForgetsTheDatabase() {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionId = UUID()
        let filters = [TestFixtures.makeTableFilter(column: "email", value: "a@b.com")]
        for schema in ["public", "billing"] {
            storage.saveLastFilters(
                PersistedFilterState(filters: filters),
                for: "users", connectionId: connectionId, databaseName: "db", schemaName: schema
            )
        }
        storage.saveLastFilters(
            PersistedFilterState(filters: filters),
            for: "users", connectionId: connectionId, databaseName: "other", schemaName: "public"
        )

        storage.dropContainer(connectionId: connectionId, database: "db", schema: nil)
        storage.waitForPendingDiskWrites()

        for schema in ["public", "billing"] {
            #expect(
                storage.loadLastFilters(
                    for: "users", connectionId: connectionId, databaseName: "db", schemaName: schema
                ).isEmpty
            )
        }
        #expect(
            storage.loadLastFilters(
                for: "users", connectionId: connectionId, databaseName: "other", schemaName: "public"
            ) == filters
        )
    }

    @Test("Saving then loading round-trips the filters")
    func roundTripsSaveAndLoad() {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionId = UUID()
        let filters = [TestFixtures.makeTableFilter(column: "email", value: "a@b.com")]

        storage.saveLastFilters(PersistedFilterState(filters: filters), for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil)

        #expect(
            storage.loadLastFilters(for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil) == filters
        )
    }

    @Test("Saving then loading preserves the order of several filters")
    func roundTripsFilterOrder() {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionId = UUID()
        let filters = [
            TestFixtures.makeTableFilter(column: "id", value: "42"),
            TestFixtures.makeTableFilter(column: "name", op: .contains, value: "ana"),
            TestFixtures.makeTableFilter(column: "age", op: .greaterThan, value: "18"),
        ]

        storage.saveLastFilters(PersistedFilterState(filters: filters), for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil)

        let loaded = storage.loadLastFilters(
            for: "users",
            connectionId: connectionId,
            databaseName: "db",
            schemaName: nil
        )
        #expect(loaded == filters)
        #expect(loaded.map(\.columnName) == ["id", "name", "age"])
    }

    /// The delete runs on the storage's IO queue, so a load that arrives first used to read the file
    /// still on disk and hand back what the reader had just cleared.
    @Test("Clearing hides the saved filters before the file is gone")
    func clearHidesFiltersBeforeTheDeleteLands() {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionId = UUID()
        let filters = [TestFixtures.makeTableFilter(column: "id", value: "1")]

        storage.saveLastFilters(PersistedFilterState(filters: filters), for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil)
        storage.waitForPendingDiskWrites()
        storage.clearLastFilters(for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil)

        #expect(
            storage.loadLastFilters(for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil)
                .isEmpty
        )
    }

    @Test("Saving no filters hides them before the file is gone")
    func savingNoFiltersHidesThemBeforeTheDeleteLands() {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionId = UUID()
        let filters = [TestFixtures.makeTableFilter(column: "id", value: "1")]

        storage.saveLastFilters(PersistedFilterState(filters: filters), for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil)
        storage.waitForPendingDiskWrites()
        storage.saveLastFilters(PersistedFilterState(filters: []), for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil)

        #expect(
            storage.loadLastFilters(for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil)
                .isEmpty
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

        storage.saveLastFilters(PersistedFilterState(filters: filtersA), for: "users", connectionId: connectionA, databaseName: "db", schemaName: nil)

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

        storage.saveLastFilters(PersistedFilterState(filters: filters), for: "users", connectionId: connectionId, databaseName: "db_a", schemaName: nil)

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

        storage.saveLastFilters(PersistedFilterState(filters: filters), for: "users", connectionId: connectionId, databaseName: "db", schemaName: "public")

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
            PersistedFilterState(filters: deletedFilters),
            for: "users", connectionId: deletedConnection, databaseName: "db", schemaName: nil
        )
        storage.saveLastFilters(
            PersistedFilterState(filters: keptFilters),
            for: "users", connectionId: keptConnection, databaseName: "db", schemaName: nil
        )

        storage.purgeConnections([deletedConnection])
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
                PersistedFilterState(filters: [TestFixtures.makeTableFilter(column: "a")]),
                for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil
            )
        }

        storage.purgeConnections([first, second])
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
            PersistedFilterState(filters: [TestFixtures.makeTableFilter(column: "a")]),
            for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil
        )

        storage.purgeConnections([connectionId])
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
            PersistedFilterState(filters: [TestFixtures.makeTableFilter()]),
            for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil
        )
        storage.saveLastFilters(PersistedFilterState(filters: []), for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil)
        storage.waitForPendingDiskWrites()

        #expect(
            storage.loadLastFilters(for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil).isEmpty
        )
    }

    @Test("New installs restore and apply the saved filter, with the bar shown only when there is one")
    func defaultSettingsRestoreAndApply() {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(storage.loadSettings().restoreBehavior == .restoreAndApply)
        #expect(!storage.loadSettings().alwaysShowPanel)
    }

    @Test(
        "A settings file written before the two axes were split maps onto both",
        arguments: [
            ("restoreLast", FilterRestoreBehavior.restoreAndApply, false),
            ("alwaysShow", FilterRestoreBehavior.restoreAndApply, true),
            ("alwaysHide", FilterRestoreBehavior.dontSave, false),
        ]
    )
    func legacyPanelStateMapsOntoBothAxes(
        stored: String,
        behavior: FilterRestoreBehavior,
        alwaysShowPanel: Bool
    ) throws {
        let defaults = try #require(UserDefaults(suiteName: "FilterSettingsStorageTests-\(UUID().uuidString)"))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilterSettingsStorageTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacy = """
        {"defaultColumn":"rawSQL","defaultOperator":"equal","panelState":"\(stored)"}
        """
        defaults.set(Data(legacy.utf8), forKey: "com.TablePro.filter.settings")

        let settings = FilterSettingsStorage(filterStateDirectory: directory, defaults: defaults).loadSettings()

        #expect(settings.restoreBehavior == behavior)
        #expect(settings.alwaysShowPanel == alwaysShowPanel)
    }

    /// The rewrite this replaced ran once behind a UserDefaults flag, so anyone who set the value
    /// again afterwards kept it. Reading it in the decoder holds for every launch instead.
    @Test("Reading a legacy settings file twice gives the same answer")
    func legacyPanelStateMigrationIsIdempotent() throws {
        let defaults = try #require(UserDefaults(suiteName: "FilterSettingsStorageTests-\(UUID().uuidString)"))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilterSettingsStorageTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacy = """
        {"defaultColumn":"rawSQL","defaultOperator":"equal","panelState":"alwaysHide"}
        """
        defaults.set(Data(legacy.utf8), forKey: "com.TablePro.filter.settings")

        _ = FilterSettingsStorage(filterStateDirectory: directory, defaults: defaults).loadSettings()
        let second = FilterSettingsStorage(filterStateDirectory: directory, defaults: defaults).loadSettings()

        #expect(second.restoreBehavior == .dontSave)
    }

    @Test("A draft saved with nothing applied round-trips as a draft")
    func draftRoundTripsUnapplied() {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionId = UUID()
        let filters = [TestFixtures.makeTableFilter(column: "email", value: "a@b.com")]

        storage.saveLastFilters(
            PersistedFilterState(filters: filters, isApplied: false),
            for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil
        )

        let state = storage.loadLastFilterState(
            for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil
        )
        #expect(state.filters == filters)
        #expect(!state.isApplied)
    }

    /// Every file written before the flag existed held a set that was running.
    @Test("A saved file with no applied flag decodes as applied")
    func legacyFilterFileDecodesAsApplied() throws {
        let defaults = try #require(UserDefaults(suiteName: "FilterSettingsStorageTests-\(UUID().uuidString)"))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilterSettingsStorageTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionId = UUID()

        let writer = FilterSettingsStorage(filterStateDirectory: directory, defaults: defaults)
        writer.saveLastFilters(
            PersistedFilterState(filters: [TestFixtures.makeTableFilter(column: "email", value: "a@b.com")]),
            for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil
        )
        writer.waitForPendingDiskWrites()

        let file = try #require(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" }
        )
        var raw = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        raw.removeValue(forKey: "isApplied")
        try JSONSerialization.data(withJSONObject: raw).write(to: file)

        let reader = FilterSettingsStorage(filterStateDirectory: directory, defaults: defaults)
        #expect(
            reader.loadLastFilterState(
                for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil
            ).isApplied
        )
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
        writer.saveLastFilters(PersistedFilterState(filters: filters), for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil)
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

        storage.saveLastFilters(PersistedFilterState(filters: filters), for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil)
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
        writer.saveLastFilters(PersistedFilterState(filters: filters), for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil)
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

    @Test("The filter logic mode round-trips alongside the filters")
    func logicModeRoundTrips() {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionId = UUID()
        let filters = [
            TestFixtures.makeTableFilter(column: "a"),
            TestFixtures.makeTableFilter(column: "b"),
        ]

        storage.saveLastFilters(
            PersistedFilterState(filters: filters, logicMode: .or),
            for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil
        )

        let state = storage.loadLastFilterState(
            for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil
        )
        #expect(state.filters == filters)
        #expect(state.logicMode == .or)
    }

    @Test("The logic mode survives a fresh storage instance")
    func logicModePersistsAcrossInstances() throws {
        let defaults = try #require(UserDefaults(suiteName: "FilterSettingsStorageTests-\(UUID().uuidString)"))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilterSettingsStorageTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionId = UUID()

        let writer = FilterSettingsStorage(filterStateDirectory: directory, defaults: defaults)
        writer.saveLastFilters(
            PersistedFilterState(filters: [TestFixtures.makeTableFilter(column: "a")], logicMode: .or),
            for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil
        )
        writer.waitForPendingDiskWrites()

        let reader = FilterSettingsStorage(filterStateDirectory: directory, defaults: defaults)
        #expect(
            reader.loadLastFilterState(
                for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil
            ).logicMode == .or
        )
    }

    @Test("A legacy bare-array filter file loads with the default AND logic mode")
    func legacyArrayFileLoadsWithAndMode() throws {
        let defaults = try #require(UserDefaults(suiteName: "FilterSettingsStorageTests-\(UUID().uuidString)"))
        defaults.set(true, forKey: "com.TablePro.filterStateMigrationComplete")
        defaults.set(true, forKey: "com.TablePro.filterStateCompositeKeyMigrationComplete")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilterSettingsStorageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionId = UUID()
        let filters = [TestFixtures.makeTableFilter(column: "email", value: "a@b.com")]

        let storage = FilterSettingsStorage(filterStateDirectory: directory, defaults: defaults)
        let compositeKey = CompositeStorageKey.make(
            connectionId: connectionId, databaseName: "db", schemaName: nil, tableName: "users"
        )
        let fileURL = directory.appendingPathComponent("\(compositeKey).json")
        try JSONEncoder().encode(filters).write(to: fileURL)

        let state = storage.loadLastFilterState(
            for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil
        )
        #expect(state.filters == filters)
        #expect(state.logicMode == .and)
    }

    @Test("A table rename moves its filters and browse search and leaves a longer name alone")
    func renameTableMovesFiltersAndBrowseSearch() throws {
        let defaults = try #require(UserDefaults(suiteName: "FilterSettingsStorageTests-\(UUID().uuidString)"))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilterSettingsStorageTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionId = UUID()
        let filters = [TestFixtures.makeTableFilter(column: "email", value: "a@b.com")]
        let archiveFilters = [TestFixtures.makeTableFilter(column: "id", value: "1")]
        let search = BrowseSearchState(pattern: "user:*", typeScope: "hash")

        let storage = FilterSettingsStorage(filterStateDirectory: directory, defaults: defaults)
        storage.saveLastFilters(PersistedFilterState(filters: filters), for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil)
        storage.saveLastFilters(
            PersistedFilterState(filters: archiveFilters),
            for: "users_archive", connectionId: connectionId, databaseName: "db", schemaName: nil
        )
        storage.saveBrowseSearch(search, for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil)

        storage.renameTable(
            from: TableScope(connectionId: connectionId, database: "db", schema: nil, table: "users"),
            to: TableScope(connectionId: connectionId, database: "db", schema: nil, table: "members")
        )
        storage.waitForPendingDiskWrites()

        for reader in [storage, FilterSettingsStorage(filterStateDirectory: directory, defaults: defaults)] {
            #expect(
                reader.loadLastFilters(for: "members", connectionId: connectionId, databaseName: "db", schemaName: nil)
                    == filters
            )
            #expect(
                reader.loadBrowseSearch(for: "members", connectionId: connectionId, databaseName: "db", schemaName: nil)
                    == search
            )
            #expect(
                reader.loadLastFilters(for: "users", connectionId: connectionId, databaseName: "db", schemaName: nil)
                    .isEmpty
            )
            #expect(
                reader.loadLastFilters(
                    for: "users_archive", connectionId: connectionId, databaseName: "db", schemaName: nil
                ) == archiveFilters
            )
        }
    }

    @Test("A schema rename moves browse search along with the filters")
    func renameContainerMovesBrowseSearch() throws {
        let defaults = try #require(UserDefaults(suiteName: "FilterSettingsStorageTests-\(UUID().uuidString)"))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilterSettingsStorageTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionId = UUID()
        let filters = [TestFixtures.makeTableFilter(column: "email", value: "a@b.com")]
        let search = BrowseSearchState(pattern: "user:*", typeScope: "hash")

        let storage = FilterSettingsStorage(filterStateDirectory: directory, defaults: defaults)
        storage.saveLastFilters(PersistedFilterState(filters: filters), for: "users", connectionId: connectionId, databaseName: "db", schemaName: "app")
        storage.saveBrowseSearch(search, for: "users", connectionId: connectionId, databaseName: "db", schemaName: "app")

        storage.renameContainer(
            connectionId: connectionId, fromDatabase: "db", fromSchema: "app", toDatabase: "db", toSchema: "core"
        )
        storage.waitForPendingDiskWrites()

        for reader in [storage, FilterSettingsStorage(filterStateDirectory: directory, defaults: defaults)] {
            #expect(
                reader.loadLastFilters(for: "users", connectionId: connectionId, databaseName: "db", schemaName: "core")
                    == filters
            )
            #expect(
                reader.loadBrowseSearch(for: "users", connectionId: connectionId, databaseName: "db", schemaName: "core")
                    == search
            )
            #expect(
                !reader.loadBrowseSearch(for: "users", connectionId: connectionId, databaseName: "db", schemaName: "app")
                    .isActive
            )
        }
    }
}
