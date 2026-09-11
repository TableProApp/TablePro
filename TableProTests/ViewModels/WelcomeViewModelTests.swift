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
        viewModel = makeViewModel()
    }

    private func makeViewModel() -> WelcomeViewModel {
        WelcomeViewModel(
            services: makeServices(),
            importableAppDetector: { false },
            groupExpansionStore: WelcomeGroupExpansionStore(defaults: defaults)
        )
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
            appSettingsStorage: AppSettingsStorage(userDefaults: defaults),
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

        try viewModel.createGroup(name: "Production", color: .red, parentId: nil)

        let created = try XCTUnwrap(groupStorage.loadGroups().first { $0.name == "Production" })
        XCTAssertTrue(groupIds(in: viewModel.treeItems).contains(created.id))
        XCTAssertTrue(viewModel.expandedGroupIds.contains(created.id))
    }

    func testCreateSubgroupExpandsParentAndChild() throws {
        try viewModel.createGroup(name: "Parent", color: .none, parentId: nil)
        let parentId = try XCTUnwrap(groupStorage.loadGroups().first { $0.name == "Parent" }?.id)

        try viewModel.createGroup(name: "Child", color: .none, parentId: parentId)
        let childId = try XCTUnwrap(groupStorage.loadGroups().first { $0.name == "Child" }?.id)

        XCTAssertTrue(groupIds(in: viewModel.treeItems).contains(parentId))
        XCTAssertTrue(groupIds(in: viewModel.treeItems).contains(childId))
        XCTAssertTrue(viewModel.expandedGroupIds.contains(parentId))
        XCTAssertTrue(viewModel.expandedGroupIds.contains(childId))
    }

    func testCreateDuplicateNameReportsWhyAndAddsNoSecondNode() throws {
        try viewModel.createGroup(name: "Staging", color: .orange, parentId: nil)

        XCTAssertThrowsError(try viewModel.createGroup(name: "staging", color: .blue, parentId: nil)) { error in
            XCTAssertEqual(error as? GroupStorageError, .duplicateName("staging"))
        }

        let stagingNodes = groupIds(in: viewModel.treeItems).filter { id in
            viewModel.groups.first { $0.id == id }?.name.lowercased() == "staging"
        }
        XCTAssertEqual(stagingNodes.count, 1)
    }

    // MARK: - List State

    func testAnEmptyStoreOpensOnTheFirstRunState() {
        viewModel.loadConnections()

        XCTAssertEqual(viewModel.listState, .firstRun)
        XCTAssertFalse(viewModel.isSearchAvailable)
    }

    func testASavedConnectionReplacesTheFirstRunState() {
        connectionStorage.saveConnections([DatabaseConnection(name: "Local", type: .postgresql, sortOrder: 0)])
        viewModel.loadConnections()

        XCTAssertEqual(viewModel.listState, .content)
        XCTAssertTrue(viewModel.isSearchAvailable)
    }

    func testASearchMissIsReportedWhenAFavoriteIsStored() {
        var favorite = DatabaseConnection(name: "Alpha", type: .mysql, sortOrder: 0)
        favorite.isFavorite = true
        connectionStorage.saveConnections([favorite])
        viewModel.loadConnections()

        viewModel.searchText = "zzz"

        XCTAssertEqual(viewModel.listState, .noSearchMatch("zzz"))
    }

    func testATagFilterThatHidesEveryConnectionIsAFilterMiss() {
        let first = UUID()
        let second = UUID()
        var alpha = DatabaseConnection(name: "Alpha", type: .mysql, sortOrder: 0)
        alpha.tagIds = [first]
        var beta = DatabaseConnection(name: "Beta", type: .mysql, sortOrder: 1)
        beta.tagIds = [second]
        connectionStorage.saveConnections([alpha, beta])
        viewModel.loadConnections()

        viewModel.tagFilter = TagFilter(selectedIds: [first, second], mode: .all)

        XCTAssertEqual(viewModel.listState, .noFilterMatch)
    }

    func testDeletingTheLastConnectionClearsTheSearchItCanNoLongerRun() {
        let only = DatabaseConnection(name: "Only", type: .mysql, sortOrder: 0)
        connectionStorage.saveConnections([only])
        viewModel.loadConnections()
        viewModel.searchText = "On"

        viewModel.connectionsToDelete = [only]
        viewModel.deleteSelectedConnections()

        XCTAssertEqual(viewModel.searchText, "")
        XCTAssertEqual(viewModel.listState, .firstRun)
    }

    func testTheImportOfferFollowsTheInstalledAppDetector() {
        let offering = WelcomeViewModel(
            services: makeServices(),
            importableAppDetector: { true },
            groupExpansionStore: WelcomeGroupExpansionStore(defaults: defaults)
        )

        offering.setUp()

        XCTAssertTrue(offering.hasImportableApp)
        XCTAssertFalse(viewModel.hasImportableApp)
    }

    // MARK: - Welcome Sheet

    func testAFirstLaunchPresentsTheWelcomeSheetOnce() {
        viewModel.setUp()
        XCTAssertTrue(viewModel.presentsWelcomeSheet)

        viewModel.presentsWelcomeSheet = false
        viewModel.welcomeSheetDidDismiss()
        let relaunched = makeViewModel()
        relaunched.setUp()

        XCTAssertFalse(relaunched.presentsWelcomeSheet, "The sheet must not come back on its own")
    }

    func testARoutedSheetWinsOverTheWelcomeSheet() {
        welcomeRouter.route(.importFromApp)

        viewModel.setUp()

        XCTAssertFalse(viewModel.presentsWelcomeSheet)
        XCTAssertNotNil(viewModel.activeSheet)
    }

    func testTheHelpMenuRequestShowsTheSheetAgain() {
        AppSettingsStorage(userDefaults: defaults).markWelcomeSheetSeen()
        viewModel.setUp()
        XCTAssertFalse(viewModel.presentsWelcomeSheet)

        viewModel.handle(.showWelcomeSheet)

        XCTAssertTrue(viewModel.presentsWelcomeSheet)
    }

    func testTheHelpMenuRequestLeavesAnOpenSheetAlone() {
        AppSettingsStorage(userDefaults: defaults).markWelcomeSheetSeen()
        viewModel.setUp()
        viewModel.activeSheet = .activation

        viewModel.handle(.showWelcomeSheet)

        XCTAssertFalse(viewModel.presentsWelcomeSheet, "A second sheet can never stack, so the request must not wait stuck")
    }

    // MARK: - Favorites, Tags and Groups

    func testAFavoriteInsideAGroupIsListedOnlyUnderFavorites() throws {
        let group = ConnectionGroup(name: "Acme")
        try groupStorage.addGroup(group)
        var favorite = DatabaseConnection(name: "Prod", type: .mysql, sortOrder: 0)
        favorite.groupId = group.id
        favorite.isFavorite = true
        var other = DatabaseConnection(name: "Staging", type: .mysql, sortOrder: 1)
        other.groupId = group.id
        connectionStorage.saveConnections([favorite, other])

        viewModel.loadConnections()

        guard case .group(_, let children)? = viewModel.treeItems.first else {
            XCTFail("The group is missing from the tree")
            return
        }
        XCTAssertEqual(renderedConnectionIds(children), [other.id])
        XCTAssertEqual(viewModel.favoriteConnections.map(\.id), [favorite.id])
    }

    func testASearchListsAGroupedFavoriteInsideItsGroup() throws {
        let group = ConnectionGroup(name: "Acme")
        try groupStorage.addGroup(group)
        var favorite = DatabaseConnection(name: "Prod", type: .mysql, sortOrder: 0)
        favorite.groupId = group.id
        favorite.isFavorite = true
        connectionStorage.saveConnections([favorite])
        viewModel.loadConnections()

        viewModel.searchText = "Prod"

        guard case .group(_, let children)? = viewModel.treeItems.first else {
            XCTFail("A search must still reach a favorite through its group")
            return
        }
        XCTAssertEqual(renderedConnectionIds(children), [favorite.id])
    }

    func testDeletingTheLastTaggedConnectionDropsItsTagFromTheFilter() {
        let tagId = UUID()
        var tagged = DatabaseConnection(name: "Prod", type: .mysql, sortOrder: 0)
        tagged.tagIds = [tagId]
        let plain = DatabaseConnection(name: "Dev", type: .mysql, sortOrder: 1)
        connectionStorage.saveConnections([tagged, plain])
        viewModel.loadConnections()
        viewModel.tagFilter = TagFilter(selectedIds: [tagId])

        viewModel.connectionsToDelete = [tagged]
        viewModel.deleteSelectedConnections()

        XCTAssertFalse(viewModel.tagFilter.isActive, "A filter on a tag nothing carries hides every connection")
        XCTAssertEqual(renderedConnectionIds(viewModel.treeItems), [plain.id])
        XCTAssertEqual(viewModel.listState, .content)
    }

    func testCollapsingEveryGroupSurvivesAReopen() throws {
        let group = ConnectionGroup(name: "Acme")
        try groupStorage.addGroup(group)
        viewModel.setUp()
        XCTAssertEqual(viewModel.expandedGroupIds, [group.id], "A first open expands every group")

        viewModel.expandedGroupIds.remove(group.id)
        let reopened = makeViewModel()
        reopened.setUp()

        XCTAssertTrue(reopened.expandedGroupIds.isEmpty, "Collapsing every group must be remembered")
    }

    func testATaggedFavoriteLeavesNoEmptyGroupUnderTheTagFilter() throws {
        let group = ConnectionGroup(name: "Acme")
        try groupStorage.addGroup(group)
        let tagId = UUID()
        var favorite = DatabaseConnection(name: "Prod", type: .mysql, sortOrder: 0)
        favorite.groupId = group.id
        favorite.isFavorite = true
        favorite.tagIds = [tagId]
        var untagged = DatabaseConnection(name: "Dev", type: .mysql, sortOrder: 1)
        untagged.groupId = group.id
        connectionStorage.saveConnections([favorite, untagged])
        viewModel.loadConnections()

        viewModel.tagFilter = TagFilter(selectedIds: [tagId])

        XCTAssertTrue(viewModel.treeItems.isEmpty, "A group whose only match moved to Favorites must not stay behind empty")
        XCTAssertEqual(viewModel.favoriteConnections.map(\.id), [favorite.id])
    }

    func testReplacingLinkedConnectionsReappliesTheFilters() {
        let tagId = UUID()
        var tagged = DatabaseConnection(name: "Prod", type: .mysql, sortOrder: 0)
        tagged.tagIds = [tagId]
        let plain = DatabaseConnection(name: "Dev", type: .mysql, sortOrder: 1)
        connectionStorage.saveConnections([tagged, plain])
        viewModel.loadConnections()
        viewModel.tagFilter = TagFilter(selectedIds: [tagId])
        connectionStorage.saveConnections([plain])
        viewModel.connections = connectionStorage.loadConnections()

        viewModel.linkedConnections = []

        XCTAssertFalse(viewModel.tagFilter.isActive, "A change to the linked rows must re-run the list's rules")
    }

    func testRefreshingTheImportOfferPicksUpANewlyInstalledApp() {
        let installed = InstalledAppFlag()
        let offering = WelcomeViewModel(
            services: makeServices(),
            importableAppDetector: { installed.value },
            groupExpansionStore: WelcomeGroupExpansionStore(defaults: defaults)
        )
        offering.refreshImportableApp()
        XCTAssertFalse(offering.hasImportableApp)

        installed.value = true
        offering.refreshImportableApp()

        XCTAssertTrue(offering.hasImportableApp)
    }

    func testLinkedConnectionsFollowTheSearchAndStepAsideForATagFilter() {
        let folderId = UUID()
        let external = ["Analytics", "Billing"].map { name in
            let payload = makeExportable(name: name)
            return LinkedConnection(
                id: LinkedFolderWatcher.stableId(folderId: folderId, connection: payload),
                connection: payload,
                folderId: folderId,
                sourceFileURL: URL(fileURLWithPath: "/tmp/\(name).tablepro")
            )
        }

        let searched = WelcomeViewModel.visibleExternalConnections(
            external,
            searchText: "bill",
            tagFilter: TagFilter()
        )
        let tagged = WelcomeViewModel.visibleExternalConnections(
            external,
            searchText: "",
            tagFilter: TagFilter(selectedIds: [UUID()])
        )

        XCTAssertEqual(searched.map(\.connection.name), ["Billing"])
        XCTAssertTrue(tagged.isEmpty, "A connection with no tags can never match a tag filter")
    }

    // MARK: - Reorder

    private func renderedConnectionIds(_ nodes: [ConnectionGroupTreeNode]) -> [UUID] {
        nodes.compactMap { node in
            guard case .connection(let conn) = node else { return nil }
            return conn.id
        }
    }

    /// The favorite is drawn in its own section, so the tree hands `.onMove` three rows while the
    /// stored array still holds four. Mapping those offsets into the array moved the connection
    /// one slot over from the one the user dragged.
    func testReorderMovesTheRowTheListDrewWhenAFavoriteIsHidden() {
        var favorite = DatabaseConnection(name: "A", type: .mysql, sortOrder: 0)
        favorite.isFavorite = true
        let b = DatabaseConnection(name: "B", type: .mysql, sortOrder: 1)
        let c = DatabaseConnection(name: "C", type: .mysql, sortOrder: 2)
        let d = DatabaseConnection(name: "D", type: .mysql, sortOrder: 3)
        connectionStorage.saveConnections([favorite, b, c, d])
        viewModel.loadConnections()

        let rendered = renderedConnectionIds(viewModel.treeItems)
        XCTAssertEqual(rendered, [b.id, c.id, d.id])

        viewModel.moveConnections(renderedIds: rendered, from: IndexSet(integer: 2), to: 0, inGroup: nil)

        XCTAssertEqual(renderedConnectionIds(viewModel.treeItems), [d.id, b.id, c.id])
        XCTAssertEqual(
            viewModel.connections.first { $0.id == favorite.id }?.sortOrder,
            0,
            "A row the list did not draw keeps the slot it held"
        )
    }

    func testReorderInsideAGroupIgnoresRowsATagFilterHid() throws {
        let group = ConnectionGroup(name: "Acme")
        try groupStorage.addGroup(group)
        let tagId = UUID()

        var hidden = DatabaseConnection(name: "Hidden", type: .mysql, sortOrder: 0)
        hidden.groupId = group.id
        var first = DatabaseConnection(name: "First", type: .mysql, sortOrder: 1)
        first.groupId = group.id
        first.tagIds = [tagId]
        var second = DatabaseConnection(name: "Second", type: .mysql, sortOrder: 2)
        second.groupId = group.id
        second.tagIds = [tagId]
        connectionStorage.saveConnections([hidden, first, second])

        viewModel.loadConnections()
        viewModel.tagFilter = TagFilter(selectedIds: [tagId])

        guard case .group(_, let children)? = viewModel.treeItems.first else {
            XCTFail("The group is missing from the tree")
            return
        }
        let rendered = renderedConnectionIds(children)
        XCTAssertEqual(rendered, [first.id, second.id])

        viewModel.moveConnections(renderedIds: rendered, from: IndexSet(integer: 1), to: 0, inGroup: group.id)

        guard case .group(_, let reordered)? = viewModel.treeItems.first else {
            XCTFail("The group is missing from the tree")
            return
        }
        XCTAssertEqual(renderedConnectionIds(reordered), [second.id, first.id])
        XCTAssertEqual(
            viewModel.connections.first { $0.id == hidden.id }?.sortOrder,
            0,
            "The filtered-out connection keeps the slot it held"
        )
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

    @MainActor
    private final class InstalledAppFlag {
        var value = false
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
