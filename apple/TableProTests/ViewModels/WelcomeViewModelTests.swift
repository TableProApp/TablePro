import Foundation
@testable import TablePro
import TableProConnectionLibrary
import TableProImport
import TableProPluginKit
import TableProSyncTransport
import TableProTestSupport
import Testing

@MainActor
final class WelcomeViewModelTests {
    private var suite: EphemeralDefaults!
    private var syncSuite: EphemeralDefaults!
    private var defaults: UserDefaults!
    private var syncDefaults: UserDefaults!
    private var connectionFileURL: URL!
    private var groupStorage: GroupStorage!
    private var connectionStorage: ConnectionStorage!
    private var welcomeRouter: WelcomeRouter!
    private var recents: RecentConnectionsStore!
    private var preferences: ConnectionListPreferences!
    private var viewModel: WelcomeViewModel!

    init() throws {
        let unique = UUID().uuidString
        suite = try EphemeralDefaults()
        syncSuite = try EphemeralDefaults()
        defaults = suite.defaults
        syncDefaults = syncSuite.defaults
        let tracker = SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: syncDefaults))
        connectionFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("welcome-\(unique)", isDirectory: true)
            .appendingPathComponent("connections.json")
        try? FileManager.default.createDirectory(
            at: connectionFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let connectionStorage = ConnectionStorage(
            fileURL: connectionFileURL,
            userDefaults: defaults,
            syncTracker: tracker
        )
        self.connectionStorage = connectionStorage
        // The parameter is an @escaping @autoclosure: `self.connectionStorage` would capture self.
        groupStorage = GroupStorage(
            userDefaults: defaults,
            syncTracker: tracker,
            connectionStorage: connectionStorage
        )
        welcomeRouter = WelcomeRouter()
        recents = RecentConnectionsStore(defaults: defaults, appEvents: AppEvents())
        preferences = ConnectionListPreferences(defaults: defaults, appEvents: AppEvents())
        viewModel = makeViewModel()
    }

    private func makeViewModel(
        importableAppDetector: @escaping @MainActor () -> Bool = { false },
        isUITestSandbox: Bool = false,
        pluginManager: PluginManager = AppServices.live.pluginManager
    ) -> WelcomeViewModel {
        WelcomeViewModel(
            services: makeServices(pluginManager: pluginManager),
            importableAppDetector: importableAppDetector,
            groupExpansionStore: WelcomeGroupExpansionStore(defaults: defaults),
            recentConnections: recents,
            listPreferences: preferences,
            isUITestSandbox: isUITestSandbox
        )
    }

    isolated deinit {
        try? FileManager.default.removeItem(at: connectionFileURL.deletingLastPathComponent())
    }

    private func makeServices(pluginManager: PluginManager) -> AppServices {
        let live = AppServices.live
        return AppServices(
            appEvents: live.appEvents,
            appSettings: live.appSettings,
            appSettingsStorage: AppSettingsStorage(userDefaults: defaults),
            connectionStorage: connectionStorage,
            databaseManager: live.databaseManager,
            pluginManager: pluginManager,
            schemaService: live.schemaService,
            schemaRefreshService: live.schemaRefreshService,
            schemaProviderRegistry: live.schemaProviderRegistry,
            catalogChangeService: live.catalogChangeService,
            sqlFavoriteManager: live.sqlFavoriteManager,
            favoriteTablesStorage: live.favoriteTablesStorage,
            favoriteDatabasesStorage: live.favoriteDatabasesStorage,
            tableFolderStorage: live.tableFolderStorage,
            aiChatStorage: live.aiChatStorage,
            aiKeyStorage: live.aiKeyStorage,
            aiAccessApprovals: live.aiAccessApprovals,
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
            welcomeRouter: welcomeRouter
        )
    }

    private func save(_ connections: [DatabaseConnection]) {
        #expect(connectionStorage.saveConnections(connections))
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

    @Test func testCreateGroupShowsImmediatelyInTheOutline() throws {
        #expect(groupIds(in: viewModel.outline).isEmpty)

        try viewModel.createGroup(name: "Production", color: .red, iconName: nil, parentId: nil, moving: [])

        let created = try #require(groupStorage.loadGroups().first { $0.name == "Production" })
        #expect(groupIds(in: viewModel.outline).contains(created.id))
        #expect(viewModel.expandedGroupIds.contains(created.id))
    }

    @Test func testCreateSubgroupExpandsParentAndChild() throws {
        try viewModel.createGroup(name: "Parent", color: .none, iconName: nil, parentId: nil, moving: [])
        let parentId = try #require(groupStorage.loadGroups().first { $0.name == "Parent" }?.id)

        try viewModel.createGroup(name: "Child", color: .none, iconName: nil, parentId: parentId, moving: [])
        let childId = try #require(groupStorage.loadGroups().first { $0.name == "Child" }?.id)

        #expect(groupIds(in: viewModel.outline).contains(parentId))
        #expect(groupIds(in: viewModel.outline).contains(childId))
        #expect(viewModel.expandedGroupIds.contains(parentId))
        #expect(viewModel.expandedGroupIds.contains(childId))
    }

    @Test func testCreateDuplicateNameReportsWhyAndAddsNoSecondNode() throws {
        try viewModel.createGroup(name: "Staging", color: .orange, iconName: nil, parentId: nil, moving: [])

        let error = #expect(throws: (any Error).self) {
            try viewModel.createGroup(name: "staging", color: .blue, iconName: nil, parentId: nil, moving: [])
        }
        #expect(error as? GroupStorageError == .duplicateName("staging"))

        #expect(groupIds(in: viewModel.outline).count == 1)
    }

    @Test func testANewGroupTakesTheConnectionsItWasRequestedFor() throws {
        let prod = DatabaseConnection(name: "Prod", type: .mysql)
        save([prod])
        viewModel.loadConnections()

        viewModel.requestNewGroup(parentId: nil, movingConnectionIds: [prod.id])
        guard case .newGroup(let request) = viewModel.activeSheet else {
            Issue.record("Move to Group > New Group must open the new group sheet")
            return
        }
        try viewModel.createGroup(name: "Acme", color: .none, iconName: nil, parentId: nil, moving: request.movingConnectionIds)

        let group = try #require(groupStorage.loadGroups().first)
        #expect(connectionStorage.loadConnection(id: prod.id)?.groupId == group.id)
    }

    @Test func testACancelledMoveToNewGroupIsNotReplayedByALaterSubgroup() throws {
        let archive = ConnectionGroup(name: "Archive")
        try groupStorage.addGroup(archive)
        let prod = DatabaseConnection(name: "Prod", type: .mysql)
        save([prod])
        viewModel.loadConnections()

        viewModel.requestNewGroup(parentId: nil, movingConnectionIds: [prod.id])
        viewModel.activeSheet = nil
        viewModel.perform(.newSubgroup(archive.id))
        guard case .newGroup(let request) = viewModel.activeSheet else {
            Issue.record("New Subgroup must open the new group sheet")
            return
        }
        try viewModel.createGroup(
            name: "2024",
            color: .none,
            iconName: nil,
            parentId: request.parentId,
            moving: request.movingConnectionIds
        )

        #expect(connectionStorage.loadConnection(id: prod.id)?.groupId == nil)
    }

    @Test func testRenamingAGroupToASiblingsNameReportsWhy() throws {
        try viewModel.createGroup(name: "Production", color: .none, iconName: nil, parentId: nil, moving: [])
        try viewModel.createGroup(name: "Staging", color: .none, iconName: nil, parentId: nil, moving: [])
        let staging = try #require(groupStorage.loadGroups().first { $0.name == "Staging" })

        viewModel.commitRename(.group(staging.id), to: "production")

        #expect(viewModel.libraryErrorMessage != nil)
        #expect(groupStorage.group(for: staging.id)?.name == "Staging")
    }

    @Test func testANewGroupKeepsTheIconItWasCreatedWith() throws {
        try viewModel.createGroup(name: "Production", color: .red, iconName: "server.rack", parentId: nil, moving: [])

        #expect(groupStorage.loadGroups().first?.iconName == "server.rack")
    }

    @Test func testEditGroupOpensTheEditSheetForThatGroup() throws {
        let group = ConnectionGroup(name: "Production", iconName: "server.rack")
        try groupStorage.addGroup(group)
        viewModel.loadConnections()

        viewModel.perform(.editGroup(group.id))

        guard case .editGroup(let editing) = viewModel.activeSheet else {
            Issue.record("Edit Group… must open the group editor")
            return
        }
        #expect(editing.id == group.id)
        #expect(editing.iconName == "server.rack")
    }

    @Test func testEditGroupForAGroupThatIsGoneOpensNothing() {
        viewModel.loadConnections()

        viewModel.requestEditGroup(UUID())

        #expect(viewModel.activeSheet == nil)
    }

    @Test func testSavingAGroupEditMovesItAndShowsItUnderItsNewParent() throws {
        let clients = ConnectionGroup(name: "Clients")
        let acme = ConnectionGroup(name: "Acme")
        try groupStorage.addGroup(clients)
        try groupStorage.addGroup(acme)
        viewModel.loadConnections()
        viewModel.expandedGroupIds = []

        try viewModel.saveGroup(
            id: acme.id,
            from: ConnectionGroupFields(acme),
            to: ConnectionGroupFields(name: "Acme Corp", color: .blue, iconName: "building.2", parentId: clients.id)
        )

        let saved = try #require(groupStorage.group(for: acme.id))
        #expect(saved.name == "Acme Corp")
        #expect(saved.color == .blue)
        #expect(saved.iconName == "building.2")
        #expect(saved.parentId == clients.id)
        #expect(viewModel.expandedGroupIds.contains(clients.id))
        #expect(viewModel.groupsById[acme.id]?.name == "Acme Corp")
    }

    @Test func testSavingAGroupEditUnderItsOwnSubgroupReportsWhyAndChangesNothing() throws {
        let parent = ConnectionGroup(name: "Parent")
        let child = ConnectionGroup(name: "Child", parentId: parent.id)
        try groupStorage.addGroup(parent)
        try groupStorage.addGroup(child)
        viewModel.loadConnections()

        let error = #expect(throws: (any Error).self) {
            try viewModel.saveGroup(
                id: parent.id,
                from: ConnectionGroupFields(parent),
                to: ConnectionGroupFields(name: "Renamed", parentId: child.id)
            )
        }
        #expect(error as? GroupStorageError == .wouldCreateCycle)
        #expect(groupStorage.group(for: parent.id)?.name == "Parent")
        #expect(groupStorage.group(for: parent.id)?.parentId == nil)
    }

    // MARK: - List State

    @Test func testAnEmptyStoreOpensOnTheFirstRunState() {
        viewModel.loadConnections()

        #expect(viewModel.listState == .firstRun)
        #expect(!viewModel.isSearchAvailable)
    }

    @Test func testASavedConnectionReplacesTheFirstRunState() {
        save([DatabaseConnection(name: "Local", type: .postgresql, sortOrder: 0)])
        viewModel.loadConnections()

        #expect(viewModel.listState == .content)
        #expect(viewModel.isSearchAvailable)
    }

    @Test func testASearchMissIsReportedWhenAFavoriteIsStored() {
        var favorite = DatabaseConnection(name: "Alpha", type: .mysql, sortOrder: 0)
        favorite.isFavorite = true
        save([favorite])
        viewModel.loadConnections()

        viewModel.searchText = "zzz"

        #expect(viewModel.listState == .noSearchMatch("zzz"))
    }

    @Test func testATagFilterThatHidesEveryConnectionIsAFilterMiss() {
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

        #expect(viewModel.listState == .noFilterMatch)
    }

    @Test func testDeletingTheLastConnectionClearsTheSearchItCanNoLongerRun() {
        let only = DatabaseConnection(name: "Only", type: .mysql, sortOrder: 0)
        save([only])
        viewModel.loadConnections()
        viewModel.searchText = "On"

        viewModel.connectionsToDelete = [only]
        viewModel.deleteSelectedConnections()

        #expect(viewModel.searchText == "")
        #expect(viewModel.listState == .firstRun)
    }

    @Test func testTheImportOfferFollowsTheInstalledAppDetector() {
        let offering = makeViewModel(importableAppDetector: { true })

        offering.setUp()

        #expect(offering.hasImportableApp)
        #expect(!viewModel.hasImportableApp)
    }

    @Test func testRefreshingTheImportOfferPicksUpANewlyInstalledApp() {
        let installed = InstalledAppFlag()
        let offering = makeViewModel(importableAppDetector: { installed.value })
        offering.refreshImportableApp()
        #expect(!offering.hasImportableApp)

        installed.value = true
        offering.refreshImportableApp()

        #expect(offering.hasImportableApp)
    }

    // MARK: - Welcome Sheet

    @Test func testAFirstLaunchPresentsTheWelcomeSheetOnce() {
        viewModel.setUp()
        #expect(viewModel.presentsWelcomeSheet)

        viewModel.presentsWelcomeSheet = false
        viewModel.welcomeSheetDidDismiss()
        let relaunched = makeViewModel()
        relaunched.setUp()

        #expect(!relaunched.presentsWelcomeSheet, "The sheet must not come back on its own")
    }

    @Test func testAUITestSandboxSkipsTheFirstLaunchSheet() {
        let sandboxed = makeViewModel(isUITestSandbox: true)
        sandboxed.setUp()

        #expect(!sandboxed.presentsWelcomeSheet)
    }

    @Test func testARoutedSheetWinsOverTheWelcomeSheet() {
        welcomeRouter.route(.importFromApp)

        viewModel.setUp()

        #expect(!viewModel.presentsWelcomeSheet)
        #expect(viewModel.activeSheet != nil)
    }

    @Test func testTheHelpMenuRequestShowsTheSheetAgain() {
        AppSettingsStorage(userDefaults: defaults).markWelcomeSheetSeen()
        viewModel.setUp()
        #expect(!viewModel.presentsWelcomeSheet)

        viewModel.handle(.showWelcomeSheet)

        #expect(viewModel.presentsWelcomeSheet)
    }

    @Test func testTheHelpMenuRequestLeavesAnOpenSheetAlone() {
        AppSettingsStorage(userDefaults: defaults).markWelcomeSheetSeen()
        viewModel.setUp()
        viewModel.activeSheet = .activation

        viewModel.handle(.showWelcomeSheet)

        #expect(!viewModel.presentsWelcomeSheet, "A second sheet can never stack, so the request must not wait stuck")
    }

    // MARK: - Favorites, Recent, Tags and Groups

    @Test func testAFavoriteAppearsInFavoritesAndStaysInItsGroup() throws {
        let group = ConnectionGroup(name: "Acme")
        try groupStorage.addGroup(group)
        var favorite = DatabaseConnection(name: "Prod", type: .mysql, sortOrder: 0)
        favorite.groupId = group.id
        favorite.isFavorite = true
        var other = DatabaseConnection(name: "Staging", type: .mysql, sortOrder: 1)
        other.groupId = group.id
        save([favorite, other])

        viewModel.loadConnections()

        #expect(viewModel.outline.connectionIds(in: .favorites) == [favorite.id])
        #expect(viewModel.outline.connectionIds(in: .connections) == [favorite.id, other.id])
    }

    @Test func testASearchHidesFavoritesAndOpensTheCollapsedGroupHoldingTheMatch() throws {
        let group = ConnectionGroup(name: "Acme")
        try groupStorage.addGroup(group)
        var favorite = DatabaseConnection(name: "Orders", type: .mysql)
        favorite.groupId = group.id
        favorite.isFavorite = true
        save([favorite])
        viewModel.loadConnections()
        viewModel.expandedGroupIds = []

        viewModel.searchText = "Orders"

        #expect(viewModel.outline.section(.favorites) == nil)
        #expect(viewModel.isGroupExpanded(group.id))
        #expect(viewModel.visibleRowIds().contains(.connection(favorite.id, section: .connections)))
        #expect(viewModel.expandedGroupIds.isEmpty, "A search must not rewrite the groups the user collapsed")
    }

    @Test func testCollapsingAGroupDropsTheSelectionInsideIt() throws {
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

        #expect(viewModel.selection.isEmpty, "A row the list no longer shows must not stay selected")
    }

    @Test func testDeletingTheLastTaggedConnectionDropsItsTokenFromTheSearch() {
        let tagId = UUID()
        var tagged = DatabaseConnection(name: "Prod", type: .mysql, sortOrder: 0)
        tagged.tagIds = [tagId]
        let plain = DatabaseConnection(name: "Dev", type: .mysql, sortOrder: 1)
        save([tagged, plain])
        viewModel.loadConnections()
        viewModel.searchTokens = [token(tagId)]

        viewModel.connectionsToDelete = [tagged]
        viewModel.deleteSelectedConnections()

        #expect(viewModel.searchTokens.isEmpty, "A token for a tag nothing carries hides every connection")
        #expect(viewModel.outline.connectionIds(in: .connections) == [plain.id])
        #expect(viewModel.listState == .content)
    }

    @Test func testCollapsingEveryGroupSurvivesAReopen() throws {
        let group = ConnectionGroup(name: "Acme")
        try groupStorage.addGroup(group)
        viewModel.setUp()
        #expect(viewModel.expandedGroupIds == [group.id], "A first open expands every group")

        viewModel.expandedGroupIds.remove(group.id)
        let reopened = makeViewModel()
        reopened.setUp()

        #expect(reopened.expandedGroupIds.isEmpty, "Collapsing every group must be remembered")
    }

    @Test func testRecentConnectionsFillTheRecentSection() {
        let first = DatabaseConnection(name: "First", type: .mysql, sortOrder: 0)
        let second = DatabaseConnection(name: "Second", type: .mysql, sortOrder: 1)
        save([first, second])
        recents.record(first.id, at: Date(timeIntervalSince1970: 1))
        recents.record(second.id, at: Date(timeIntervalSince1970: 2))

        viewModel.loadConnections()

        #expect(viewModel.outline.connectionIds(in: .recent) == [second.id, first.id])
    }

    @Test func testHidingRecentTakesEffectInTheOpenWindowAndKeepsTheHistory() {
        let first = DatabaseConnection(name: "First", type: .mysql, sortOrder: 0)
        save([first])
        recents.record(first.id, at: Date(timeIntervalSince1970: 1))
        viewModel.setUp()
        viewModel.loadConnections()
        #expect(viewModel.outline.connectionIds(in: .recent) == [first.id])

        preferences.setShowsRecent(false)

        #expect(viewModel.outline.section(.recent) == nil, "Hiding Recent must rebuild the open list")
        #expect(viewModel.outline.connectionIds(in: .connections) == [first.id])
        #expect(!recents.ledger.isEmpty, "Hiding Recent must not clear the history")

        preferences.setShowsRecent(true)

        #expect(viewModel.outline.connectionIds(in: .recent) == [first.id])
    }

    @Test func testAListOpenedWhileRecentIsHiddenStartsWithoutIt() {
        let first = DatabaseConnection(name: "First", type: .mysql, sortOrder: 0)
        save([first])
        recents.record(first.id, at: Date(timeIntervalSince1970: 1))
        preferences.setShowsRecent(false)

        let reopened = makeViewModel()
        reopened.loadConnections()

        #expect(reopened.outline.section(.recent) == nil)
    }

    @Test func testChangingTheSortModeReordersTheTree() {
        let zulu = DatabaseConnection(name: "Zulu", type: .mysql, sortOrder: 0)
        let alpha = DatabaseConnection(name: "Alpha", type: .mysql, sortOrder: 1)
        save([zulu, alpha])
        viewModel.loadConnections()
        #expect(viewModel.outline.connectionIds(in: .connections) == [zulu.id, alpha.id])

        viewModel.setSortMode(.name)

        #expect(viewModel.outline.connectionIds(in: .connections) == [alpha.id, zulu.id])
        #expect(preferences.sortMode == .name)
    }

    // MARK: - Mutations

    @Test func testAddingAFavoriteKeepsASafeModeLevelSetElsewhere() throws {
        let prod = DatabaseConnection(name: "Prod", type: .postgresql)
        save([prod])
        viewModel.loadConnections()
        #expect(connectionStorage.updateSafeModeLevel(.readOnly, for: prod.id))

        viewModel.setFavorite([prod.id], true, undoManager: nil)

        let stored = try #require(connectionStorage.loadConnection(id: prod.id))
        #expect(stored.isFavorite)
        #expect(stored.preferredSafeModeLevel == .readOnly)
    }

    @Test func testRenamingAConnectionKeepsASafeModeLevelSetElsewhere() throws {
        let prod = DatabaseConnection(name: "Prod", type: .postgresql)
        save([prod])
        viewModel.loadConnections()
        #expect(connectionStorage.updateSafeModeLevel(.readOnly, for: prod.id))

        viewModel.commitRename(.connection(prod.id, section: .connections), to: "  Production  ")

        let stored = try #require(connectionStorage.loadConnection(id: prod.id))
        #expect(stored.name == "Production")
        #expect(stored.preferredSafeModeLevel == .readOnly)
    }

    @Test func testMovingAConnectionIntoAGroupPlacesItAfterTheOnesAlreadyThere() throws {
        let group = ConnectionGroup(name: "Acme")
        try groupStorage.addGroup(group)
        var first = DatabaseConnection(name: "Zeta", type: .mysql, sortOrder: 4)
        first.groupId = group.id
        let moving = DatabaseConnection(name: "Alpha", type: .mysql, sortOrder: 0)
        save([first, moving])
        viewModel.loadConnections()

        viewModel.moveConnections([moving.id], toGroup: group.id, before: nil, undoManager: nil)

        #expect(viewModel.outline.connectionIds(in: .connections) == [first.id, moving.id])
    }

    @Test func testAManualDropPlacesTheConnectionBeforeTheTarget() {
        let a = DatabaseConnection(name: "A", type: .mysql, sortOrder: 0)
        let b = DatabaseConnection(name: "B", type: .mysql, sortOrder: 1)
        let c = DatabaseConnection(name: "C", type: .mysql, sortOrder: 2)
        save([a, b, c])
        viewModel.loadConnections()

        viewModel.applyDrop(.moveConnections([c.id], toGroup: nil, before: a.id), undoManager: nil)

        #expect(viewModel.outline.connectionIds(in: .connections) == [c.id, a.id, b.id])
    }

    @Test func testUndoPutsAMovedConnectionBack() throws {
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
        #expect(connectionStorage.loadConnection(id: moving.id)?.groupId == group.id)

        undoManager.undo()

        #expect(connectionStorage.loadConnection(id: moving.id)?.groupId == nil)
    }

    @Test func testDeleteMeansWhatTheSectionHolds() throws {
        let group = ConnectionGroup(name: "Acme")
        try groupStorage.addGroup(group)
        var favorite = DatabaseConnection(name: "Prod", type: .mysql)
        favorite.isFavorite = true
        let recent = DatabaseConnection(name: "Stage", type: .mysql)
        save([favorite, recent])
        viewModel.loadConnections()

        #expect(viewModel.deleteIntent(for: [.connection(favorite.id, section: .favorites)]) == .removeFavorites([favorite.id]))
        #expect(viewModel.deleteIntent(for: [.connection(recent.id, section: .recent)]) == .removeRecent([recent.id]))
        #expect(viewModel.deleteIntent(for: [.connection(favorite.id, section: .connections)]) == .connections([favorite.id]))
        #expect(viewModel.deleteIntent(for: [.group(group.id)]) == .group(group.id))
        #expect(viewModel.deleteIntent(for: [
            .connection(favorite.id, section: .favorites),
            .connection(recent.id, section: .connections),
        ]) == nil)
    }

    @Test func testRemovingAFavoriteRowKeepsTheConnection() {
        var favorite = DatabaseConnection(name: "Prod", type: .mysql)
        favorite.isFavorite = true
        save([favorite])
        viewModel.loadConnections()

        viewModel.performDelete(rows: [.connection(favorite.id, section: .favorites)])

        #expect(connectionStorage.loadConnection(id: favorite.id)?.isFavorite == false)
        #expect(!viewModel.showDeleteConfirmation)
    }

    // MARK: - Welcome Router Requests

    @Test func testChooserRoutedWhileWelcomeWindowIsClosedSurvivesUntilItMounts() {
        let payload = DatabaseTypeChooserPayload(initialType: .postgresql) { _ in }
        welcomeRouter.route(.chooseDatabaseType(payload))

        viewModel.setUp()

        #expect(viewModel.databaseTypeChooser?.id == payload.id)
        #expect(welcomeRouter.pendingRequest == nil)
    }

    @Test func testChooserRoutedWhileWelcomeWindowIsOpenIsDelivered() async {
        viewModel.setUp()
        #expect(viewModel.databaseTypeChooser == nil)

        let payload = DatabaseTypeChooserPayload(initialType: .mysql) { _ in }
        welcomeRouter.route(.chooseDatabaseType(payload))

        _ = try? await waitUntil { self.viewModel.databaseTypeChooser != nil }
        #expect(viewModel.databaseTypeChooser?.id == payload.id)
    }

    @Test func testImportFromURLRequestPresentsTheURLSheet() {
        welcomeRouter.route(.importFromURL)

        viewModel.setUp()

        #expect(viewModel.urlImportPresented)
    }

    @Test func testImportFromAppRequestPresentsTheImportSheet() {
        welcomeRouter.route(.importFromApp)

        viewModel.setUp()

        guard case .importFromApp = viewModel.activeSheet else {
            Issue.record("Expected the Import from Other App sheet")
            return
        }
    }

    @Test func testExportConnectionsRequestIsIgnoredWhenThereAreNoConnections() {
        welcomeRouter.route(.exportConnections)

        viewModel.setUp()

        #expect(viewModel.activeSheet == nil)
    }

    @Test func testRequestIsDrainedAheadOfABackgroundPluginInstall() {
        let connection = DatabaseConnection(name: "Pending", type: .mysql)
        welcomeRouter.routePluginInstall(connection)
        welcomeRouter.route(.importFromURL)

        viewModel.setUp()

        #expect(viewModel.urlImportPresented)
        #expect(viewModel.pluginInstallConnection == nil)
        #expect(welcomeRouter.pendingPluginInstall?.id == connection.id)
    }

    // MARK: - Delete

    @Test func testDeleteConfirmationIsNotPresentedBeforeTheFavoritesCheckFinishes() async throws {
        let connection = DatabaseConnection(name: "Prod", type: .mysql)
        save([connection])
        viewModel.loadConnections()

        viewModel.requestDeleteConnections([connection.id])

        #expect(!viewModel.showDeleteConfirmation, "The alert must wait for the favorites lookup, or it renders the wrong message")
        #expect(viewModel.connectionsToDelete.map(\.id) == [connection.id])

        try await waitUntil { self.viewModel.showDeleteConfirmation }
        #expect(!viewModel.pendingDeleteHasFavorites)
    }

    @Test func testDeleteRequestWithNoTargetsPresentsNothing() async throws {
        viewModel.requestDeleteConnections([])

        #expect(!viewModel.showDeleteConfirmation)
        #expect(viewModel.connectionsToDelete.isEmpty)
    }

    @Test func testASecondDeleteRequestSupersedesTheFirst() async throws {
        let first = DatabaseConnection(name: "First", type: .mysql)
        let second = DatabaseConnection(name: "Second", type: .mysql)
        save([first, second])
        viewModel.loadConnections()

        viewModel.requestDeleteConnections([first.id])
        viewModel.requestDeleteConnections([second.id])

        try await waitUntil { self.viewModel.showDeleteConfirmation }
        #expect(viewModel.connectionsToDelete.map(\.id) == [second.id], "The superseded request must not present an alert for its own targets")
    }

    @Test func testDeleteKeepsTheConnectionAndReportsWhenPersistenceFails() throws {
        let connection = DatabaseConnection(name: "Prod", type: .mysql)
        #expect(connectionStorage.saveConnections([connection]))
        viewModel.loadConnections()
        #expect(viewModel.connections.map(\.id) == [connection.id])

        let directory = connectionFileURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        connectionStorage.invalidateCache()
        viewModel.connectionsToDelete = [connection]
        viewModel.deleteSelectedConnections()

        #expect(viewModel.connections.map(\.id) == [connection.id], "A connection that could not be persisted as deleted must not disappear from the list")
        #expect(viewModel.connectionsToDelete.isEmpty)
        #expect(viewModel.libraryErrorMessage != nil, "A refused delete must say so")
    }

    // MARK: - Driver Plugins

    @Test func testARejectedPluginFlagsEveryConnectionOfTheTypesItProvides() {
        let pluginManager = PluginManager(
            builtInPluginsURL: nil,
            userPluginsDir: connectionFileURL.deletingLastPathComponent().appendingPathComponent("Plugins")
        )
        pluginManager.rejectedPlugins = [RejectedPlugin(
            url: URL(fileURLWithPath: "/tmp/CassandraDriver.tableplugin"),
            bundleId: "com.TablePro.CassandraDriver",
            registryId: "com.TablePro.CassandraDriver",
            name: "Cassandra Driver",
            reason: "Built for an older PluginKit",
            isOutdated: true,
            providedDatabaseTypeIds: ["Cassandra", "ScyllaDB"]
        )]
        let welcome = makeViewModel(pluginManager: pluginManager)
        let cassandra = DatabaseConnection(name: "Ring", type: .cassandra, sortOrder: 0)
        let scylla = DatabaseConnection(name: "Scylla", type: .scylladb, sortOrder: 1)
        let mysql = DatabaseConnection(name: "Shop", type: .mysql, sortOrder: 2)
        save([cassandra, scylla, mysql])

        welcome.loadConnections()

        func isDriverRejected(_ connection: DatabaseConnection) -> Bool? {
            guard case .connection(let row) = welcome.rowModel(for: .connection(connection.id, section: .connections)) else {
                return nil
            }
            return row.isDriverRejected
        }
        #expect(isDriverRejected(cassandra) == true)
        #expect(isDriverRejected(scylla) == true)
        #expect(isDriverRejected(mysql) == false)
    }

    // MARK: - Shared Connections

    @Test func testSharedRowIdsAreDerivedFromThePayloadAndAreStable() {
        let folderId = UUID()
        let payload = makeExportable(name: "Shared")

        let first = LinkedFolderWatcher.stableId(folderId: folderId, connection: payload)
        let second = LinkedFolderWatcher.stableId(folderId: folderId, connection: payload)
        let otherFolder = LinkedFolderWatcher.stableId(folderId: UUID(), connection: payload)
        let otherPayload = LinkedFolderWatcher.stableId(
            folderId: folderId,
            connection: makeExportable(name: "Different")
        )

        #expect(first == second, "A shared row must keep its identity across launches")
        #expect(first != otherFolder)
        #expect(first != otherPayload)
    }

    @Test func testSharedConnectionsThatDifferOnlyByDatabaseAreDifferentRows() {
        let folderId = UUID()
        let production = makeExportable(name: "Analytics", database: "prod")
        let staging = makeExportable(name: "Analytics", database: "staging")

        #expect(LinkedFolderWatcher.stableId(folderId: folderId, connection: production) != LinkedFolderWatcher.stableId(folderId: folderId, connection: staging))
    }

    @Test func testASharedConnectionOpensWithoutItsTunnelCommandOrStartupSQL() {
        let base = makeExportable(name: "Shared")
        let hostile = ExportableConnection(
            name: base.name,
            host: base.host,
            port: base.port,
            database: base.database,
            username: base.username,
            type: base.type,
            startupCommands: "DROP TABLE users",
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
        let opened = DatabaseConnection(
            importing: linked.connection,
            id: linked.id,
            groupId: nil,
            tagIds: [],
            credentialProfileId: nil,
            resolvesSSHProfile: { _ in false }
        )

        #expect(opened.tunnelCommandMode == .disabled, "A shared file must never start a process on connect")
        #expect(opened.startupCommands == nil, "A shared file must never run SQL on connect")
        #expect(opened.host == base.host)
        #expect(linked.id == LinkedFolderWatcher.stableId(folderId: linked.folderId, connection: hostile), "Dropping the command must not change the row's identity")
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
            type: DatabaseType.mysql.rawValue
        )
    }
}
