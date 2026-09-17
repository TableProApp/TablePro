//
//  WelcomeViewModelTests.swift
//  TableProTests
//

@testable import TablePro
import TableProConnectionLibrary
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
    private var recents: RecentConnectionsStore!
    private var preferences: ConnectionListPreferences!
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
        recents = RecentConnectionsStore(defaults: defaults, appEvents: AppEvents())
        preferences = ConnectionListPreferences(defaults: defaults, appEvents: AppEvents())
        viewModel = makeViewModel()
    }

    private func makeViewModel(importableAppDetector: @escaping @MainActor () -> Bool = { false }) -> WelcomeViewModel {
        WelcomeViewModel(
            services: makeServices(),
            importableAppDetector: importableAppDetector,
            groupExpansionStore: WelcomeGroupExpansionStore(defaults: defaults),
            recentConnections: recents,
            listPreferences: preferences
        )
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        syncDefaults.removePersistentDomain(forName: syncSuiteName)
        try? FileManager.default.removeItem(at: connectionFileURL)
        viewModel = nil
        preferences = nil
        recents = nil
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
            catalogChangeService: live.catalogChangeService,
            sqlFavoriteManager: live.sqlFavoriteManager,
            favoriteTablesStorage: live.favoriteTablesStorage,
            favoriteDatabasesStorage: live.favoriteDatabasesStorage,
            aiChatStorage: live.aiChatStorage,
            aiKeyStorage: live.aiKeyStorage,
            groupStorage: groupStorage,
            tagStorage: live.tagStorage,
            sshProfileStorage: live.sshProfileStorage,
            credentialProfileStorage: live.credentialProfileStorage,
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

    private func save(_ connections: [DatabaseConnection]) {
        XCTAssertTrue(connectionStorage.saveConnections(connections))
    }

    private func groupIds(in outline: LibraryOutline) -> [UUID] {
        func walk(_ nodes: [LibraryNode]) -> [UUID] {
            nodes.flatMap { node -> [UUID] in
                guard case .group(let id, let children, _) = node else { return [] }
                return [id] + walk(children)
            }
        }
        return walk(outline.section(.connections)?.nodes ?? [])
    }

    private func token(_ id: UUID) -> WelcomeTagToken {
        WelcomeTagToken(id: id, name: id.uuidString, color: .none)
    }

    // MARK: - Groups

    func testCreateGroupShowsImmediatelyInTheOutline() throws {
        XCTAssertTrue(groupIds(in: viewModel.outline).isEmpty)

        try viewModel.createGroup(name: "Production", color: .red, parentId: nil, moving: [])

        let created = try XCTUnwrap(groupStorage.loadGroups().first { $0.name == "Production" })
        XCTAssertTrue(groupIds(in: viewModel.outline).contains(created.id))
        XCTAssertTrue(viewModel.expandedGroupIds.contains(created.id))
    }

    func testCreateSubgroupExpandsParentAndChild() throws {
        try viewModel.createGroup(name: "Parent", color: .none, parentId: nil, moving: [])
        let parentId = try XCTUnwrap(groupStorage.loadGroups().first { $0.name == "Parent" }?.id)

        try viewModel.createGroup(name: "Child", color: .none, parentId: parentId, moving: [])
        let childId = try XCTUnwrap(groupStorage.loadGroups().first { $0.name == "Child" }?.id)

        XCTAssertTrue(groupIds(in: viewModel.outline).contains(parentId))
        XCTAssertTrue(groupIds(in: viewModel.outline).contains(childId))
        XCTAssertTrue(viewModel.expandedGroupIds.contains(parentId))
        XCTAssertTrue(viewModel.expandedGroupIds.contains(childId))
    }

    func testCreateDuplicateNameReportsWhyAndAddsNoSecondNode() throws {
        try viewModel.createGroup(name: "Staging", color: .orange, parentId: nil, moving: [])

        XCTAssertThrowsError(
            try viewModel.createGroup(name: "staging", color: .blue, parentId: nil, moving: [])
        ) { error in
            XCTAssertEqual(error as? GroupStorageError, .duplicateName("staging"))
        }

        XCTAssertEqual(groupIds(in: viewModel.outline).count, 1)
    }

    func testANewGroupTakesTheConnectionsItWasRequestedFor() throws {
        let prod = DatabaseConnection(name: "Prod", type: .mysql)
        save([prod])
        viewModel.loadConnections()

        viewModel.requestNewGroup(parentId: nil, movingConnectionIds: [prod.id])
        guard case .newGroup(let request) = viewModel.activeSheet else {
            return XCTFail("Move to Group > New Group must open the new group sheet")
        }
        try viewModel.createGroup(name: "Acme", color: .none, parentId: nil, moving: request.movingConnectionIds)

        let group = try XCTUnwrap(groupStorage.loadGroups().first)
        XCTAssertEqual(connectionStorage.loadConnection(id: prod.id)?.groupId, group.id)
    }

    func testACancelledMoveToNewGroupIsNotReplayedByALaterSubgroup() throws {
        let archive = ConnectionGroup(name: "Archive")
        try groupStorage.addGroup(archive)
        let prod = DatabaseConnection(name: "Prod", type: .mysql)
        save([prod])
        viewModel.loadConnections()

        viewModel.requestNewGroup(parentId: nil, movingConnectionIds: [prod.id])
        viewModel.activeSheet = nil
        viewModel.perform(.newSubgroup(archive.id))
        guard case .newGroup(let request) = viewModel.activeSheet else {
            return XCTFail("New Subgroup must open the new group sheet")
        }
        try viewModel.createGroup(
            name: "2024",
            color: .none,
            parentId: request.parentId,
            moving: request.movingConnectionIds
        )

        XCTAssertNil(connectionStorage.loadConnection(id: prod.id)?.groupId)
    }

    func testRenamingAGroupToASiblingsNameReportsWhy() throws {
        try viewModel.createGroup(name: "Production", color: .none, parentId: nil, moving: [])
        try viewModel.createGroup(name: "Staging", color: .none, parentId: nil, moving: [])
        let staging = try XCTUnwrap(groupStorage.loadGroups().first { $0.name == "Staging" })

        viewModel.commitRename(.group(staging.id), to: "production")

        XCTAssertNotNil(viewModel.libraryErrorMessage)
        XCTAssertEqual(groupStorage.group(for: staging.id)?.name, "Staging")
    }

    // MARK: - List State

    func testAnEmptyStoreOpensOnTheFirstRunState() {
        viewModel.loadConnections()

        XCTAssertEqual(viewModel.listState, .firstRun)
        XCTAssertFalse(viewModel.isSearchAvailable)
    }

    func testASavedConnectionReplacesTheFirstRunState() {
        save([DatabaseConnection(name: "Local", type: .postgresql, sortOrder: 0)])
        viewModel.loadConnections()

        XCTAssertEqual(viewModel.listState, .content)
        XCTAssertTrue(viewModel.isSearchAvailable)
    }

    func testASearchMissIsReportedWhenAFavoriteIsStored() {
        var favorite = DatabaseConnection(name: "Alpha", type: .mysql, sortOrder: 0)
        favorite.isFavorite = true
        save([favorite])
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
        save([alpha, beta])
        viewModel.loadConnections()

        viewModel.tagMatch = .all
        viewModel.searchTokens = [token(first), token(second)]

        XCTAssertEqual(viewModel.listState, .noFilterMatch)
    }

    func testDeletingTheLastConnectionClearsTheSearchItCanNoLongerRun() {
        let only = DatabaseConnection(name: "Only", type: .mysql, sortOrder: 0)
        save([only])
        viewModel.loadConnections()
        viewModel.searchText = "On"

        viewModel.connectionsToDelete = [only]
        viewModel.deleteSelectedConnections()

        XCTAssertEqual(viewModel.searchText, "")
        XCTAssertEqual(viewModel.listState, .firstRun)
    }

    func testTheImportOfferFollowsTheInstalledAppDetector() {
        let offering = makeViewModel(importableAppDetector: { true })

        offering.setUp()

        XCTAssertTrue(offering.hasImportableApp)
        XCTAssertFalse(viewModel.hasImportableApp)
    }

    func testRefreshingTheImportOfferPicksUpANewlyInstalledApp() {
        let installed = InstalledAppFlag()
        let offering = makeViewModel(importableAppDetector: { installed.value })
        offering.refreshImportableApp()
        XCTAssertFalse(offering.hasImportableApp)

        installed.value = true
        offering.refreshImportableApp()

        XCTAssertTrue(offering.hasImportableApp)
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

    // MARK: - Favorites, Recent, Tags and Groups

    func testAFavoriteAppearsInFavoritesAndStaysInItsGroup() throws {
        let group = ConnectionGroup(name: "Acme")
        try groupStorage.addGroup(group)
        var favorite = DatabaseConnection(name: "Prod", type: .mysql, sortOrder: 0)
        favorite.groupId = group.id
        favorite.isFavorite = true
        var other = DatabaseConnection(name: "Staging", type: .mysql, sortOrder: 1)
        other.groupId = group.id
        save([favorite, other])

        viewModel.loadConnections()

        XCTAssertEqual(viewModel.outline.connectionIds(in: .favorites), [favorite.id])
        XCTAssertEqual(viewModel.outline.connectionIds(in: .connections), [favorite.id, other.id])
    }

    func testASearchHidesFavoritesAndOpensTheCollapsedGroupHoldingTheMatch() throws {
        let group = ConnectionGroup(name: "Acme")
        try groupStorage.addGroup(group)
        var favorite = DatabaseConnection(name: "Orders", type: .mysql)
        favorite.groupId = group.id
        favorite.isFavorite = true
        save([favorite])
        viewModel.loadConnections()
        viewModel.expandedGroupIds = []

        viewModel.searchText = "Orders"

        XCTAssertNil(viewModel.outline.section(.favorites))
        XCTAssertTrue(viewModel.isGroupExpanded(group.id))
        XCTAssertTrue(viewModel.visibleRowIds().contains(.connection(favorite.id, section: .connections)))
        XCTAssertTrue(viewModel.expandedGroupIds.isEmpty, "A search must not rewrite the groups the user collapsed")
    }

    func testCollapsingAGroupDropsTheSelectionInsideIt() throws {
        let group = ConnectionGroup(name: "Acme")
        try groupStorage.addGroup(group)
        var member = DatabaseConnection(name: "Prod", type: .mysql)
        member.groupId = group.id
        save([member])
        viewModel.expandedGroupIds = [group.id]
        viewModel.loadConnections()
        viewModel.selection = [.connection(member.id, section: .connections)]

        viewModel.expandedGroupIds = []
        viewModel.rebuildOutline()

        XCTAssertTrue(viewModel.selection.isEmpty, "A row the list no longer shows must not stay selected")
    }

    func testDeletingTheLastTaggedConnectionDropsItsTokenFromTheSearch() {
        let tagId = UUID()
        var tagged = DatabaseConnection(name: "Prod", type: .mysql, sortOrder: 0)
        tagged.tagIds = [tagId]
        let plain = DatabaseConnection(name: "Dev", type: .mysql, sortOrder: 1)
        save([tagged, plain])
        viewModel.loadConnections()
        viewModel.searchTokens = [token(tagId)]

        viewModel.connectionsToDelete = [tagged]
        viewModel.deleteSelectedConnections()

        XCTAssertTrue(viewModel.searchTokens.isEmpty, "A token for a tag nothing carries hides every connection")
        XCTAssertEqual(viewModel.outline.connectionIds(in: .connections), [plain.id])
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

    func testRecentConnectionsFillTheRecentSection() {
        let first = DatabaseConnection(name: "First", type: .mysql, sortOrder: 0)
        let second = DatabaseConnection(name: "Second", type: .mysql, sortOrder: 1)
        save([first, second])
        recents.record(first.id, at: Date(timeIntervalSince1970: 1))
        recents.record(second.id, at: Date(timeIntervalSince1970: 2))

        viewModel.loadConnections()

        XCTAssertEqual(viewModel.outline.connectionIds(in: .recent), [second.id, first.id])
    }

    func testChangingTheSortModeReordersTheTree() {
        let zulu = DatabaseConnection(name: "Zulu", type: .mysql, sortOrder: 0)
        let alpha = DatabaseConnection(name: "Alpha", type: .mysql, sortOrder: 1)
        save([zulu, alpha])
        viewModel.loadConnections()
        XCTAssertEqual(viewModel.outline.connectionIds(in: .connections), [zulu.id, alpha.id])

        viewModel.setSortMode(.name)

        XCTAssertEqual(viewModel.outline.connectionIds(in: .connections), [alpha.id, zulu.id])
        XCTAssertEqual(preferences.sortMode, .name)
    }

    // MARK: - Mutations

    func testAddingAFavoriteKeepsASafeModeLevelSetElsewhere() throws {
        let prod = DatabaseConnection(name: "Prod", type: .postgresql)
        save([prod])
        viewModel.loadConnections()
        XCTAssertTrue(connectionStorage.updateSafeModeLevel(.readOnly, for: prod.id))

        viewModel.setFavorite([prod.id], true, undoManager: nil)

        let stored = try XCTUnwrap(connectionStorage.loadConnection(id: prod.id))
        XCTAssertTrue(stored.isFavorite)
        XCTAssertEqual(stored.preferredSafeModeLevel, .readOnly)
    }

    func testRenamingAConnectionKeepsASafeModeLevelSetElsewhere() throws {
        let prod = DatabaseConnection(name: "Prod", type: .postgresql)
        save([prod])
        viewModel.loadConnections()
        XCTAssertTrue(connectionStorage.updateSafeModeLevel(.readOnly, for: prod.id))

        viewModel.commitRename(.connection(prod.id, section: .connections), to: "  Production  ")

        let stored = try XCTUnwrap(connectionStorage.loadConnection(id: prod.id))
        XCTAssertEqual(stored.name, "Production")
        XCTAssertEqual(stored.preferredSafeModeLevel, .readOnly)
    }

    func testMovingAConnectionIntoAGroupPlacesItAfterTheOnesAlreadyThere() throws {
        let group = ConnectionGroup(name: "Acme")
        try groupStorage.addGroup(group)
        var first = DatabaseConnection(name: "Zeta", type: .mysql, sortOrder: 4)
        first.groupId = group.id
        let moving = DatabaseConnection(name: "Alpha", type: .mysql, sortOrder: 0)
        save([first, moving])
        viewModel.loadConnections()

        viewModel.moveConnections([moving.id], toGroup: group.id, before: nil, undoManager: nil)

        XCTAssertEqual(viewModel.outline.connectionIds(in: .connections), [first.id, moving.id])
    }

    func testAManualDropPlacesTheConnectionBeforeTheTarget() {
        let a = DatabaseConnection(name: "A", type: .mysql, sortOrder: 0)
        let b = DatabaseConnection(name: "B", type: .mysql, sortOrder: 1)
        let c = DatabaseConnection(name: "C", type: .mysql, sortOrder: 2)
        save([a, b, c])
        viewModel.loadConnections()

        viewModel.applyDrop(.moveConnections([c.id], toGroup: nil, before: a.id), undoManager: nil)

        XCTAssertEqual(viewModel.outline.connectionIds(in: .connections), [c.id, a.id, b.id])
    }

    func testUndoPutsAMovedConnectionBack() throws {
        let group = ConnectionGroup(name: "Acme")
        try groupStorage.addGroup(group)
        let moving = DatabaseConnection(name: "Prod", type: .mysql)
        save([moving])
        viewModel.loadConnections()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false

        undoManager.beginUndoGrouping()
        viewModel.moveConnections([moving.id], toGroup: group.id, before: nil, undoManager: undoManager)
        undoManager.endUndoGrouping()
        XCTAssertEqual(connectionStorage.loadConnection(id: moving.id)?.groupId, group.id)

        undoManager.undo()

        XCTAssertNil(connectionStorage.loadConnection(id: moving.id)?.groupId)
    }

    func testDeleteMeansWhatTheSectionHolds() throws {
        let group = ConnectionGroup(name: "Acme")
        try groupStorage.addGroup(group)
        var favorite = DatabaseConnection(name: "Prod", type: .mysql)
        favorite.isFavorite = true
        let recent = DatabaseConnection(name: "Stage", type: .mysql)
        save([favorite, recent])
        viewModel.loadConnections()

        XCTAssertEqual(
            viewModel.deleteIntent(for: [.connection(favorite.id, section: .favorites)]),
            .removeFavorites([favorite.id])
        )
        XCTAssertEqual(
            viewModel.deleteIntent(for: [.connection(recent.id, section: .recent)]),
            .removeRecent([recent.id])
        )
        XCTAssertEqual(
            viewModel.deleteIntent(for: [.connection(favorite.id, section: .connections)]),
            .connections([favorite.id])
        )
        XCTAssertEqual(viewModel.deleteIntent(for: [.group(group.id)]), .group(group.id))
        XCTAssertNil(viewModel.deleteIntent(for: [
            .connection(favorite.id, section: .favorites),
            .connection(recent.id, section: .connections),
        ]))
    }

    func testRemovingAFavoriteRowKeepsTheConnection() {
        var favorite = DatabaseConnection(name: "Prod", type: .mysql)
        favorite.isFavorite = true
        save([favorite])
        viewModel.loadConnections()

        viewModel.performDelete(rows: [.connection(favorite.id, section: .favorites)])

        XCTAssertEqual(connectionStorage.loadConnection(id: favorite.id)?.isFavorite, false)
        XCTAssertFalse(viewModel.showDeleteConfirmation)
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

    // MARK: - Delete

    func testDeleteConfirmationIsNotPresentedBeforeTheFavoritesCheckFinishes() async throws {
        let connection = DatabaseConnection(name: "Prod", type: .mysql)
        save([connection])
        viewModel.loadConnections()

        viewModel.requestDeleteConnections([connection.id])

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
        save([first, second])
        viewModel.loadConnections()

        viewModel.requestDeleteConnections([first.id])
        viewModel.requestDeleteConnections([second.id])

        try await waitUntil { self.viewModel.showDeleteConfirmation }
        XCTAssertEqual(
            viewModel.connectionsToDelete.map(\.id),
            [second.id],
            "The superseded request must not present an alert for its own targets"
        )
    }

    func testDeleteKeepsTheConnectionAndReportsWhenPersistenceFails() throws {
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
        XCTAssertNotNil(viewModel.libraryErrorMessage, "A refused delete must say so")
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

    // MARK: - Shared Connections

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

    func testSharedConnectionsThatDifferOnlyByDatabaseAreDifferentRows() {
        let folderId = UUID()
        let production = makeExportable(name: "Analytics", database: "prod")
        let staging = makeExportable(name: "Analytics", database: "staging")

        XCTAssertNotEqual(
            LinkedFolderWatcher.stableId(folderId: folderId, connection: production),
            LinkedFolderWatcher.stableId(folderId: folderId, connection: staging)
        )
    }

    func testASharedConnectionOpensWithoutItsTunnelCommandOrStartupSQL() {
        let base = makeExportable(name: "Shared")
        let hostile = ExportableConnection(
            name: base.name,
            host: base.host,
            port: base.port,
            database: base.database,
            username: base.username,
            type: base.type,
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
            startupCommands: "DROP TABLE users",
            localOnly: nil,
            tunnelCommand: ExportableTunnelCommand(
                method: "custom",
                command: "/bin/sh -c 'touch /tmp/shared-file-ran'",
                executablePath: nil,
                kubernetesNamespace: nil,
                kubernetesResource: nil,
                kubernetesContext: nil,
                awsTarget: nil,
                awsProfile: nil,
                awsRegion: nil
            )
        )

        let linked = LinkedFolderWatcher.linkedConnection(
            folderId: UUID(),
            sourceFileURL: URL(fileURLWithPath: "/tmp/shared.tablepro"),
            exportable: hostile
        )
        let opened = ConnectionExportService.buildDatabaseConnection(
            id: linked.id,
            from: linked.connection,
            name: linked.connection.name,
            tagIdsByName: [:],
            groupIdsByName: [:]
        )

        XCTAssertEqual(opened.tunnelCommandMode, .disabled, "A shared file must never start a process on connect")
        XCTAssertNil(opened.startupCommands, "A shared file must never run SQL on connect")
        XCTAssertEqual(opened.host, base.host)
        XCTAssertEqual(
            linked.id,
            LinkedFolderWatcher.stableId(folderId: linked.folderId, connection: hostile),
            "Dropping the command must not change the row's identity"
        )
    }

    @MainActor
    private final class InstalledAppFlag {
        var value = false
    }

    private func makeExportable(name: String, database: String = "app") -> ExportableConnection {
        ExportableConnection(
            name: name,
            host: "db.example.com",
            port: 3_306,
            database: database,
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
