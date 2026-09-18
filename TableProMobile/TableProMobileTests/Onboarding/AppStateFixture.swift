import CloudKit
import Foundation
@testable import TableProMobile
import TableProModels
import TableProSync
import TableProSyncTransport
import Testing

@MainActor
struct AppStateFixture {
    let root: URL
    let libraryDirectory: URL
    let documentsDirectory: URL
    let defaults: UserDefaults
    let metadata: SyncMetadataStorage
    let bookmarkStore: FileBookmarkStore
    let containerHistory: AppContainerHistory
    let bundledSample: URL

    var container: AppContainerPaths {
        AppContainerPaths(documentsDirectory: documentsDirectory, history: containerHistory)
    }

    var localFiles: LocalDatabaseFileLocator {
        LocalDatabaseFileLocator(container: container)
    }

    var connectionsFile: URL {
        libraryDirectory.appendingPathComponent("connections.json")
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-state-\(UUID().uuidString)", isDirectory: true)
        libraryDirectory = root.appendingPathComponent("Library", isDirectory: true)
        documentsDirectory = root
            .appendingPathComponent("Data/Application/\(UUID().uuidString)/Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        let suffix = UUID().uuidString
        defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.AppState.\(suffix)"))
        metadata = SyncMetadataStorage(userDefaults: defaults)
        bookmarkStore = FileBookmarkStore(suiteName: "com.TablePro.tests.Bookmarks.\(suffix)")
        containerHistory = AppContainerHistory(suiteName: "com.TablePro.tests.Containers.\(suffix)")
        bundledSample = root.appendingPathComponent("Chinook.sqlite")
        try Data("sample".utf8).write(to: bundledSample)
    }

    func makeState(syncEnabled: Bool) -> AppState {
        let coordinator = IOSSyncCoordinator(
            metadata: metadata,
            recordCache: SyncRecordCache(directory: root.appendingPathComponent("Cache"), defaults: nil),
            makeTransport: { UnreachableTransport() },
            isEnabled: { syncEnabled },
            notificationCenter: NotificationCenter()
        )
        return AppState(
            libraryDirectory: libraryDirectory,
            defaults: defaults,
            syncCoordinator: coordinator,
            sampleInstaller: SampleDatabaseInstaller(
                bundledURL: bundledSample,
                directory: root.appendingPathComponent("Samples", isDirectory: true)
            ),
            localDatabaseFiles: localFiles,
            bookmarkStore: bookmarkStore
        )
    }

    func makeFormViewModel(editing connection: DatabaseConnection? = nil) -> ConnectionFormViewModel {
        ConnectionFormViewModel(
            editing: connection,
            localFiles: localFiles,
            fileCreator: DriverDatabaseFileCreator(),
            bookmarkStore: bookmarkStore
        )
    }

    func earlierContainerPath(to relativePath: String) -> String {
        let containerId = UUID().uuidString
        containerHistory.record(containerId)
        return containerPath(containerId, to: relativePath)
    }

    func otherInstallContainerPath(to relativePath: String) -> String {
        containerPath(UUID().uuidString, to: relativePath)
    }

    private func containerPath(_ containerId: String, to relativePath: String) -> String {
        documentsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(containerId, isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(relativePath)
            .path
    }

    func documentsFile(_ name: String) -> URL {
        documentsDirectory.appendingPathComponent(name)
    }
}

private struct UnreachableTransport: IOSSyncTransport {
    var currentZoneID: CKRecordZone.ID {
        get async { CKRecordZone.ID(zoneName: "Unused", ownerName: CKCurrentUserDefaultName) }
    }

    func accountStatus() async throws -> CKAccountStatus {
        .noAccount
    }

    func currentAccountId() async throws -> String {
        throw CKError(.notAuthenticated)
    }

    func ensureZoneExists() async throws {}

    func pull(since token: CKServerChangeToken?) async throws -> PullResult {
        PullResult(changedRecords: [], deletedRecordIDs: [], newToken: nil)
    }

    func push(records: [CKRecord], deletions: [CKRecord.ID]) async throws -> PushOutcome {
        PushOutcome(savedRecords: [:], deletedRecordIDs: [])
    }
}
