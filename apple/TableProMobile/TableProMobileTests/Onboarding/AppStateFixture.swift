import Foundation
import TableProDatabase
import TableProFFI
@testable import TableProMobile
import TableProModels
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

    var coreConnectionsFile: URL {
        libraryDirectory.appendingPathComponent("Core/connections.json")
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

    func makeState(
        syncEnabled: Bool,
        secureStore: any SecureStore = MockSecureStore(),
        libraryPublisher: ConnectionLibraryPublisher? = nil,
        engine: FakeIOSSyncEngine? = nil,
        driverFactory: (any DriverFactory)? = nil
    ) -> AppState {
        let database = HeldCloudKitDatabase()
        let host = IOSSyncEngineHost(transport: CloudKitCoreTransport(database: database)) { _, _ in
            guard let engine else { throw CocoaError(.featureUnsupported) }
            return engine
        }
        let coordinator = IOSSyncCoordinator(
            host: host,
            metadata: metadata,
            isEnabled: { syncEnabled },
            database: database,
            notificationCenter: NotificationCenter(),
            makeNetworkMonitor: { nil },
            pushRegistrar: .inert
        )
        return AppState(
            libraryDirectory: libraryDirectory,
            defaults: defaults,
            secureStore: secureStore,
            syncCoordinator: coordinator,
            sampleInstaller: SampleDatabaseInstaller(
                bundledURL: bundledSample,
                directory: root.appendingPathComponent("Samples", isDirectory: true)
            ),
            localDatabaseFiles: localFiles,
            bookmarkStore: bookmarkStore,
            libraryPublisher: libraryPublisher ?? ConnectionLibraryPublisher(
                searchIndex: RecordingSearchIndex(),
                readWidgetItems: { [] },
                writeWidgetItems: { _ in },
                refreshShortcutParameters: {},
                defaults: defaults
            ),
            driverFactory: driverFactory
        )
    }

    // A change another device made, as the engine's pass writes it to the core's library; the app reads it back as it
    // does after every pass.
    func pull(_ connections: [DatabaseConnection], into state: AppState, through engine: FakeIOSSyncEngine) async {
        let directory = libraryDirectory
        engine.update { $0.pass = { _ in try? ElsewhereWriter.replace(connections: connections, in: directory) } }
        await state.syncCoordinator.sync(.userRequest)
        engine.update { $0.pass = nil }
    }

    func makeFormViewModel(
        editing connection: DatabaseConnection? = nil,
        certificateStore: any CertificateMaterialStoring = InMemoryCertificateStore()
    ) -> ConnectionFormViewModel {
        ConnectionFormViewModel(
            editing: connection,
            localFiles: localFiles,
            fileCreator: DriverDatabaseFileCreator(),
            bookmarkStore: bookmarkStore,
            certificateStore: certificateStore
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
