//
//  TransientConnectionLedgerTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProUtilities
import Testing

@MainActor
struct TransientConnectionLedgerTests {
    private let suite: EphemeralDefaults
    private let ledger: TransientConnectionLedger
    private let fileURL: URL
    private let library: ConnectionStorage

    init() throws {
        suite = try EphemeralDefaults()
        ledger = TransientConnectionLedger(defaults: suite.defaults)
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("transient-ledger-\(UUID().uuidString).json")
        library = ConnectionStorage(fileURL: fileURL, userDefaults: suite.defaults, keychain: InMemoryKeychain())
    }

    private func connection(origin: ConnectionOrigin = .thisMac) -> DatabaseConnection {
        var connection = TestFixtures.makeConnection(type: .sqlite)
        connection.origin = origin
        return connection
    }

    @Test("A connection opened from a file is recorded, and a saved one is not")
    func fileOpenIsRecorded() {
        let opened = connection()
        let saved = connection()
        library.addConnection(saved)

        ledger.recordIfTransient(opened, library: library)
        ledger.recordIfTransient(saved, library: library)

        #expect(ledger.ids == [opened.id])
    }

    @Test("Linked folder and team connections are never recorded", arguments: [ConnectionOrigin.linkedFolder, .teamLibrary])
    func stableOriginsAreNotRecorded(origin: ConnectionOrigin) {
        ledger.recordIfTransient(connection(origin: origin), library: library)
        #expect(ledger.ids.isEmpty)
    }

    @Test("A link connection is recorded")
    func linkIsRecorded() {
        let link = connection(origin: .link)
        ledger.recordIfTransient(link, library: library)
        #expect(ledger.ids == [link.id])
    }

    @Test("Nothing is recorded while the library failed to load")
    func failedLibraryRecordsNothing() throws {
        try Data("not json".utf8).write(to: fileURL)
        library.invalidateCache()

        ledger.recordIfTransient(connection(), library: library)

        #expect(library.lastLoadFailed)
        #expect(ledger.ids.isEmpty)
    }

    @Test("An unreadable library id is never transient")
    func unreadableIdIsNotTransient() {
        let unreadable = connection()
        #expect(!TransientConnectionLedger.isTransient(
            unreadable, libraryLoaded: true, savedIds: [], unreadableIds: [unreadable.id]
        ))
        #expect(TransientConnectionLedger.isTransient(
            unreadable, libraryLoaded: true, savedIds: [], unreadableIds: []
        ))
    }

    @Test("The launch purges an unreachable id, keeps an open one, and lets a saved one go with its state")
    func launchPurgesOnlyUnreachableIds() {
        let closed = connection()
        let open = connection()
        let savedLater = connection()
        for opened in [closed, open, savedLater] {
            ledger.recordIfTransient(opened, library: library)
        }
        library.addConnection(savedLater)

        var purged: Set<UUID> = []
        ledger.purgeUnreachable(library: library, openSessionIds: [open.id]) { purged.formUnion($0) }

        #expect(purged == [closed.id])
        #expect(ledger.ids == [open.id])
    }

    @Test("A library that fails at launch keeps the ledger and purges nothing")
    func failedLibraryKeepsTheLedger() throws {
        let opened = connection()
        ledger.recordIfTransient(opened, library: library)
        try Data("not json".utf8).write(to: fileURL)
        library.invalidateCache()

        var purged: Set<UUID> = []
        ledger.purgeUnreachable(library: library, openSessionIds: []) { purged.formUnion($0) }

        #expect(purged.isEmpty)
        #expect(ledger.ids == [opened.id])
    }

    @Test("Purging view state removes the three families purge used to miss, and leaves another id's")
    func viewStatePurgeRemovesTheMissedFamilies() throws {
        let gone = UUID()
        let kept = UUID()
        let autosave = try EphemeralDefaults()
        for id in [gone, kept] {
            suite.defaults.set(Data("{}".utf8), forKey: "com.TablePro.sidebar.treeExpansion.\(id.uuidString)")
            QuickSwitcherFrecencyStore(connectionId: id, defaults: suite.defaults).recordAccess(itemId: "table:users")
            for name in [SplitViewAutosaveName.historyDrawer(connectionId: id), SplitViewAutosaveName.querySplit(connectionId: id)] {
                autosave.defaults.set(["0,0,10,10"], forKey: SplitViewAutosaveKey.key(forAutosaveName: name))
            }
        }

        ConnectionLocalState.purgeViewState(
            [gone],
            defaults: suite.defaults,
            removeAutosaveRecords: { SplitViewAutosaveName.removeRecords(connectionId: $0, defaults: autosave.defaults) }
        )

        #expect(suite.defaults.object(forKey: "com.TablePro.sidebar.treeExpansion.\(gone.uuidString)") == nil)
        #expect(suite.defaults.object(forKey: "com.TablePro.sidebar.treeExpansion.\(kept.uuidString)") != nil)
        #expect(QuickSwitcherFrecencyStore(connectionId: gone, defaults: suite.defaults).recentItemIds().isEmpty)
        #expect(QuickSwitcherFrecencyStore(connectionId: kept, defaults: suite.defaults).recentItemIds() == ["table:users"])
        let goneDrawer = SplitViewAutosaveKey.key(forAutosaveName: SplitViewAutosaveName.historyDrawer(connectionId: gone))
        let goneSplit = SplitViewAutosaveKey.key(forAutosaveName: SplitViewAutosaveName.querySplit(connectionId: gone))
        let keptDrawer = SplitViewAutosaveKey.key(forAutosaveName: SplitViewAutosaveName.historyDrawer(connectionId: kept))
        #expect(autosave.defaults.object(forKey: goneDrawer) == nil)
        #expect(autosave.defaults.object(forKey: goneSplit) == nil)
        #expect(autosave.defaults.object(forKey: keptDrawer) != nil)
    }

    @Test("An unreachable connection loses its tab state file")
    func unreachablePurgeRemovesTabState() {
        let id = UUID()
        let tab = PersistedTab(id: UUID(), title: "One", query: "SELECT 1", tabType: .query, tableName: nil)
        TabDiskActor.saveSync(connectionId: id, tabs: [tab], selectedTabId: tab.id)
        let stateFile = AppStorageEnvironment.shared.applicationSupportRoot
            .appendingPathComponent("TablePro/TabState/\(id.uuidString).json")
        #expect(FileManager.default.fileExists(atPath: stateFile.path))

        ConnectionLocalState.purgeUnreachable([id], tableScopedStores: [])

        #expect(!FileManager.default.fileExists(atPath: stateFile.path))
    }

    @Test("Registering a session for a file connection records it in the ledger")
    func registeringAFileSessionRecordsIt() {
        let manager = DatabaseManager(connectionStorage: library)
        let opened = connection()
        let shared = TransientConnectionLedger()
        defer {
            manager.removeSession(for: opened.id)
            shared.purgeUnreachable(library: library, openSessionIds: []) { _ in }
        }

        manager.registerPendingSession(opened)

        #expect(shared.ids.contains(opened.id))
    }
}
