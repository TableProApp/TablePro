import CloudKit
import Foundation
@testable import TableProMobile
import TableProModels
import TableProSync
import TableProSyncTransport
import Testing

@MainActor
@Suite("App state library writes")
struct AppStateLibraryTests {
    private let root: URL
    private let libraryDirectory: URL
    private let defaults: UserDefaults
    private let metadata: SyncMetadataStorage
    private let bundledSample: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-state-\(UUID().uuidString)", isDirectory: true)
        libraryDirectory = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.AppState.\(UUID().uuidString)"))
        metadata = SyncMetadataStorage(userDefaults: defaults)
        bundledSample = root.appendingPathComponent("Chinook.sqlite")
        try Data("sample".utf8).write(to: bundledSample)
    }

    private func makeState(syncEnabled: Bool) -> AppState {
        let coordinator = IOSSyncCoordinator(
            metadata: metadata,
            recordCache: SyncRecordCache(directory: root.appendingPathComponent("Cache"), defaults: nil),
            makeTransport: { UnreachableTransport() },
            isEnabled: { syncEnabled }
        )
        return AppState(
            libraryDirectory: libraryDirectory,
            defaults: defaults,
            syncCoordinator: coordinator,
            sampleInstaller: SampleDatabaseInstaller(
                bundledURL: bundledSample,
                directory: root.appendingPathComponent("Samples", isDirectory: true)
            )
        )
    }

    @Test("A library that failed to load refuses every write and leaves the file alone")
    func failedLoadRefusesWrites() throws {
        let file = libraryDirectory.appendingPathComponent("connections.json")
        let unreadable = Data("{ not json".utf8)
        try unreadable.write(to: file)
        let state = makeState(syncEnabled: false)

        #expect(state.loadStatus == .failed)
        #expect(state.isLibraryWritable == false)
        #expect(state.addConnection(DatabaseConnection(name: "New", type: .mysql)) == false)
        #expect(state.addGroup(ConnectionGroup(name: "Team")) == false)
        #expect(throws: SampleDatabaseError.libraryUnavailable) {
            try state.openSampleDatabase()
        }
        #expect(try Data(contentsOf: file) == unreadable)
    }

    @Test("Opening the sample twice keeps one sample connection, and it is never marked for sync")
    func sampleIsLocal() throws {
        let state = makeState(syncEnabled: true)

        let first = try state.openSampleDatabase()
        let second = try state.openSampleDatabase()

        #expect(first == second)
        #expect(state.connections.filter(\.isSample).count == 1)
        #expect(state.connections.first?.database == SampleDatabaseInstaller.fileName)
        #expect(!metadata.dirtyIds(for: .connection).contains(first.uuidString))

        state.removeConnections([first])
        #expect(metadata.tombstones(for: .connection).isEmpty)
    }

    @Test("An ordinary connection is marked for sync while sync is on")
    func ordinaryConnectionIsMarked() {
        let state = makeState(syncEnabled: true)
        let connection = DatabaseConnection(name: "Prod", type: .postgresql)

        #expect(state.addConnection(connection))
        #expect(metadata.dirtyIds(for: .connection).contains(connection.id.uuidString))
    }

    @Test("A change made while sync is off waits for sync instead of being dropped")
    func changeWaitsWhileOff() {
        let state = makeState(syncEnabled: false)
        let connection = DatabaseConnection(name: "Prod", type: .postgresql)

        #expect(state.addConnection(connection))
        #expect(metadata.dirtyIds(for: .connection).contains(connection.id.uuidString))
    }

    @Test("Closing the first run without answering records every question as declined")
    func dismissedFirstRunDeclines() {
        let state = makeState(syncEnabled: false)

        state.finishFirstRun(pages: [.welcome, .iCloud, .usageData])

        #expect(state.onboarding.hasSeenWelcome)
        #expect(state.onboarding.syncChoice == false)
        #expect(state.onboarding.usageDataChoice == false)
    }

    @Test("An answer given during the first run is kept when the sheet closes")
    func answeredChoiceKept() {
        let state = makeState(syncEnabled: false)
        state.setUsageDataEnabled(true)

        state.finishFirstRun(pages: [.welcome, .usageData])

        #expect(state.onboarding.usageDataChoice == true)
    }
}

private struct UnreachableTransport: IOSSyncTransport {
    var currentZoneID: CKRecordZone.ID {
        get async { CKRecordZone.ID(zoneName: "Unused", ownerName: CKCurrentUserDefaultName) }
    }

    func accountStatus() async throws -> CKAccountStatus {
        .noAccount
    }

    func ensureZoneExists() async throws {}

    func pull(since token: CKServerChangeToken?) async throws -> PullResult {
        PullResult(changedRecords: [], deletedRecordIDs: [], newToken: nil)
    }

    func push(records: [CKRecord], deletions: [CKRecord.ID]) async throws -> PushOutcome {
        PushOutcome(savedRecords: [:], deletedRecordIDs: [])
    }
}
