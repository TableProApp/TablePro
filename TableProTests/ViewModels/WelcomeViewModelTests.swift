//
//  WelcomeViewModelTests.swift
//  TableProTests
//

@testable import TablePro
import TableProImport
import TableProPluginKit
import TableProSyncTransport
import XCTest

@MainActor
final class WelcomeViewModelTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var syncSuiteName: String!
    private var syncDefaults: UserDefaults!
    private var connectionFileURL: URL!
    private var groupStorage: GroupStorage!
    private var connectionStorage: ConnectionStorage!
    private var welcomeRouter: WelcomeRouter!
    private var viewModel: WelcomeViewModel!

    override func setUp() async throws {
        try await super.setUp()
        let unique = UUID().uuidString
        suiteName = "com.TablePro.tests.WelcomeViewModel.\(unique)"
        syncSuiteName = "com.TablePro.tests.WelcomeViewModel.sync.\(unique)"
        guard let defaults = UserDefaults(suiteName: suiteName),
              let syncDefaults = UserDefaults(suiteName: syncSuiteName) else {
            XCTFail("Could not create isolated UserDefaults suites")
            return
        }
        self.defaults = defaults
        self.syncDefaults = syncDefaults
        let tracker = SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: syncDefaults))
        connectionFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("welcome-connections_\(unique).json")
        try? FileManager.default.createDirectory(
            at: connectionFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        connectionStorage = ConnectionStorage(
            fileURL: connectionFileURL,
            userDefaults: defaults,
            syncTracker: tracker
        )
        groupStorage = GroupStorage(
            userDefaults: defaults,
            syncTracker: tracker,
            connectionStorage: self.connectionStorage
        )
        welcomeRouter = WelcomeRouter()
        viewModel = WelcomeViewModel(services: makeServices())
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        syncDefaults.removePersistentDomain(forName: syncSuiteName)
        try? FileManager.default.removeItem(at: connectionFileURL)
        viewModel = nil
        welcomeRouter = nil
        groupStorage = nil
        connectionStorage = nil
        defaults = nil
        syncDefaults = nil
        suiteName = nil
        syncSuiteName = nil
        connectionFileURL = nil
        super.tearDown()
    }

    private func makeServices() -> AppServices {
        let live = AppServices.live
        return AppServices(
            appEvents: live.appEvents,
            appSettings: live.appSettings,
            appSettingsStorage: live.appSettingsStorage,
            connectionStorage: connectionStorage,
            databaseManager: live.databaseManager,
            pluginManager: live.pluginManager,
            schemaService: live.schemaService,
            schemaRefreshService: live.schemaRefreshService,
            schemaProviderRegistry: live.schemaProviderRegistry,
            sqlFavoriteManager: live.sqlFavoriteManager,
            favoriteTablesStorage: live.favoriteTablesStorage,
            favoriteDatabasesStorage: live.favoriteDatabasesStorage,
            aiChatStorage: live.aiChatStorage,
            aiKeyStorage: live.aiKeyStorage,
            groupStorage: groupStorage,
            tagStorage: live.tagStorage,
            sshProfileStorage: live.sshProfileStorage,
            licenseManager: live.licenseManager,
            syncMetadataStorage: live.syncMetadataStorage,
            favoritesExpansionState: live.favoritesExpansionState,
            linkedFolderWatcher: live.linkedFolderWatcher,
            queryHistoryManager: live.queryHistoryManager,
            dateFormattingService: live.dateFormattingService,
            copilotService: live.copilotService,
            mcpServerManager: live.mcpServerManager,
            syncTracker: live.syncTracker,
            themeEngine: live.themeEngine,
            welcomeRouter: welcomeRouter
        )
    }

    private func groupIds(in nodes: [ConnectionGroupTreeNode]) -> [UUID] {
        nodes.flatMap { node -> [UUID] in
            guard case .group(let group, let children) = node else { return [] }
            return [group.id] + groupIds(in: children)
        }
    }

    func testCreateGroupShowsImmediatelyInTree() throws {
        XCTAssertTrue(groupIds(in: viewModel.treeItems).isEmpty)

        viewModel.createGroup(name: "Production", color: .red, parentId: nil)

        let created = try XCTUnwrap(groupStorage.loadGroups().first { $0.name == "Production" })
        XCTAssertTrue(groupIds(in: viewModel.treeItems).contains(created.id))
        XCTAssertTrue(viewModel.expandedGroupIds.contains(created.id))
    }

    func testCreateSubgroupExpandsParentAndChild() throws {
        viewModel.createGroup(name: "Parent", color: .none, parentId: nil)
        let parentId = try XCTUnwrap(groupStorage.loadGroups().first { $0.name == "Parent" }?.id)

        viewModel.createGroup(name: "Child", color: .none, parentId: parentId)
        let childId = try XCTUnwrap(groupStorage.loadGroups().first { $0.name == "Child" }?.id)

        XCTAssertTrue(groupIds(in: viewModel.treeItems).contains(parentId))
        XCTAssertTrue(groupIds(in: viewModel.treeItems).contains(childId))
        XCTAssertTrue(viewModel.expandedGroupIds.contains(parentId))
        XCTAssertTrue(viewModel.expandedGroupIds.contains(childId))
    }

    func testCreateDuplicateNameDoesNotAddSecondNode() {
        viewModel.createGroup(name: "Staging", color: .orange, parentId: nil)
        viewModel.createGroup(name: "staging", color: .blue, parentId: nil)

        let stagingNodes = groupIds(in: viewModel.treeItems).filter { id in
            viewModel.groups.first { $0.id == id }?.name.lowercased() == "staging"
        }
        XCTAssertEqual(stagingNodes.count, 1)
    }

    // MARK: - Welcome Router Requests

    private func waitForChooser(timeout: TimeInterval = 2) async -> DatabaseTypeChooserPayload? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let chooser = viewModel.databaseTypeChooser {
                return chooser
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return viewModel.databaseTypeChooser
    }

    func testChooserRoutedWhileWelcomeWindowIsClosedSurvivesUntilItMounts() {
        let payload = DatabaseTypeChooserPayload(initialType: .postgresql) { _ in }
        welcomeRouter.route(.chooseDatabaseType(payload))

        viewModel.setUp()

        XCTAssertEqual(viewModel.databaseTypeChooser?.id, payload.id)
        XCTAssertNil(welcomeRouter.pendingRequest)
    }

    func testChooserRoutedWhileWelcomeWindowIsOpenIsDelivered() async {
        viewModel.setUp()
        XCTAssertNil(viewModel.databaseTypeChooser)

        let payload = DatabaseTypeChooserPayload(initialType: .mysql) { _ in }
        welcomeRouter.route(.chooseDatabaseType(payload))

        let delivered = await waitForChooser()
        XCTAssertEqual(delivered?.id, payload.id)
    }

    func testImportFromURLRequestPresentsTheURLSheet() {
        welcomeRouter.route(.importFromURL)

        viewModel.setUp()

        XCTAssertTrue(viewModel.urlImportPresented)
    }

    func testImportFromAppRequestPresentsTheImportSheet() {
        welcomeRouter.route(.importFromApp)

        viewModel.setUp()

        guard case .importFromApp = viewModel.activeSheet else {
            return XCTFail("Expected the Import from Other App sheet")
        }
    }

    func testExportConnectionsRequestIsIgnoredWhenThereAreNoConnections() {
        welcomeRouter.route(.exportConnections)

        viewModel.setUp()

        XCTAssertNil(viewModel.activeSheet)
    }

    func testRequestIsDrainedAheadOfABackgroundPluginInstall() {
        let connection = DatabaseConnection(name: "Pending", type: .mysql)
        welcomeRouter.routePluginInstall(connection)
        welcomeRouter.route(.importFromURL)

        viewModel.setUp()

        XCTAssertTrue(viewModel.urlImportPresented)
        XCTAssertNil(viewModel.pluginInstallConnection)
        XCTAssertEqual(welcomeRouter.pendingPluginInstall?.id, connection.id)
    }

    func testDeleteConfirmationIsNotPresentedBeforeTheFavoritesCheckFinishes() async throws {
        let connection = DatabaseConnection(name: "Prod", type: .mysql)

        viewModel.requestDeleteConnections([connection])

        XCTAssertFalse(
            viewModel.showDeleteConfirmation,
            "The alert must wait for the favorites lookup, or it renders the wrong message"
        )
        XCTAssertEqual(viewModel.connectionsToDelete.map(\.id), [connection.id])

        try await waitUntil { self.viewModel.showDeleteConfirmation }
        XCTAssertFalse(viewModel.pendingDeleteHasFavorites)
    }

    func testDeleteRequestWithNoTargetsPresentsNothing() async throws {
        viewModel.requestDeleteConnections([])

        XCTAssertFalse(viewModel.showDeleteConfirmation)
        XCTAssertTrue(viewModel.connectionsToDelete.isEmpty)
    }

    func testASecondDeleteRequestSupersedesTheFirst() async throws {
        let first = DatabaseConnection(name: "First", type: .mysql)
        let second = DatabaseConnection(name: "Second", type: .mysql)

        viewModel.requestDeleteConnections([first])
        viewModel.requestDeleteConnections([second])

        try await waitUntil { self.viewModel.showDeleteConfirmation }
        XCTAssertEqual(
            viewModel.connectionsToDelete.map(\.id),
            [second.id],
            "The superseded request must not present an alert for its own targets"
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Condition never became true within \(timeout)s", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    func testAFavoritedUngroupedConnectionStaysReachableFromTheKeyboard() {
        var favorited = DatabaseConnection(name: "Starred", type: .mysql)
        favorited.isFavorite = true
        let plain = DatabaseConnection(name: "Plain", type: .mysql)
        connectionStorage.saveConnections([favorited, plain])

        viewModel.loadConnections()

        XCTAssertEqual(viewModel.favoriteConnections.map(\.id), [favorited.id])
        XCTAssertFalse(
            viewModel.treeItems.contains { node in
                if case .connection(let conn) = node { return conn.id == favorited.id }
                return false
            },
            "A favorited ungrouped connection is rendered in the Favorites section, not the tree"
        )
        XCTAssertEqual(
            Set(viewModel.flatVisibleConnections.map(\.id)),
            [favorited.id, plain.id],
            "Select All and Ctrl+J walk flatVisibleConnections, so it must include the Favorites section"
        )
    }

    func testFlatVisibleConnectionsListsEachConnectionOnce() {
        var favorited = DatabaseConnection(name: "Starred", type: .mysql)
        favorited.isFavorite = true
        connectionStorage.saveConnections([favorited])

        viewModel.loadConnections()

        let ids = viewModel.flatVisibleConnections.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Ctrl+J must never visit the same connection twice")
    }

    func testDeleteKeepsTheConnectionWhenPersistenceFails() throws {
        let connection = DatabaseConnection(name: "Prod", type: .mysql)
        XCTAssertTrue(connectionStorage.saveConnections([connection]))
        viewModel.loadConnections()
        XCTAssertEqual(viewModel.connections.map(\.id), [connection.id])

        let directory = connectionFileURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        connectionStorage.invalidateCache()
        viewModel.connectionsToDelete = [connection]
        viewModel.deleteSelectedConnections()

        XCTAssertEqual(
            viewModel.connections.map(\.id),
            [connection.id],
            "A connection that could not be persisted as deleted must not disappear from the list"
        )
        XCTAssertTrue(viewModel.connectionsToDelete.isEmpty)
    }

    func testSharedRowIdsAreDerivedFromThePayloadAndAreStable() {
        let folderId = UUID()
        let payload = makeExportable(name: "Shared")

        let first = LinkedFolderWatcher.stableId(folderId: folderId, connection: payload)
        let second = LinkedFolderWatcher.stableId(folderId: folderId, connection: payload)
        let otherFolder = LinkedFolderWatcher.stableId(folderId: UUID(), connection: payload)
        let otherPayload = LinkedFolderWatcher.stableId(
            folderId: folderId,
            connection: makeExportable(name: "Different")
        )

        XCTAssertEqual(first, second, "A shared row must keep its identity across launches")
        XCTAssertNotEqual(first, otherFolder)
        XCTAssertNotEqual(first, otherPayload)
    }

    private func makeExportable(name: String) -> ExportableConnection {
        ExportableConnection(
            name: name,
            host: "db.example.com",
            port: 3_306,
            database: "app",
            username: "reader",
            type: DatabaseType.mysql.rawValue,
            sshConfig: nil,
            sslConfig: nil,
            color: nil,
            tagName: nil,
            groupName: nil,
            sshProfileId: nil,
            safeModeLevel: nil,
            aiPolicy: nil,
            additionalFields: nil,
            redisDatabase: nil,
            startupCommands: nil,
            localOnly: nil
        )
    }
}
