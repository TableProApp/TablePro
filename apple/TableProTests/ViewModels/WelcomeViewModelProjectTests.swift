import AppKit
import Foundation
@testable import TablePro
import TableProConnectionLibrary
import TableProTestSupport
import Testing

@MainActor
struct WelcomeViewModelProjectTests {
    private let fixture: ProjectLibraryFixture
    private let tags: TagStorage
    private let recents: RecentConnectionsStore
    private let preferences: ConnectionListPreferences
    private let viewModel: WelcomeViewModel

    init() throws {
        let fixture = try ProjectLibraryFixture()
        self.fixture = fixture
        tags = TagStorage(userDefaults: fixture.defaults, syncTracker: fixture.tracker, appEvents: fixture.appEvents)
        recents = RecentConnectionsStore(defaults: fixture.defaults, appEvents: fixture.appEvents)
        preferences = ConnectionListPreferences(defaults: fixture.defaults, appEvents: fixture.appEvents)
        viewModel = WelcomeViewModel(
            services: Self.services(fixture: fixture, tags: tags),
            importableAppDetector: { false },
            groupExpansionStore: WelcomeGroupExpansionStore(defaults: fixture.defaults),
            recentConnections: recents,
            listPreferences: preferences,
            scope: fixture.scope,
            isUITestSandbox: true
        )
    }

    private static func services(fixture: ProjectLibraryFixture, tags: TagStorage) -> AppServices {
        let live = AppServices.live
        return AppServices(
            appEvents: fixture.appEvents,
            appSettings: live.appSettings,
            appSettingsStorage: AppSettingsStorage(userDefaults: fixture.defaults),
            connectionStorage: fixture.connections,
            databaseManager: live.databaseManager,
            pluginManager: live.pluginManager,
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
            groupStorage: fixture.groups,
            tagStorage: tags,
            sshProfileStorage: live.sshProfileStorage,
            credentialProfileStorage: live.credentialProfileStorage,
            featureAccess: live.featureAccess,
            syncMetadataStorage: live.syncMetadataStorage,
            favoritesExpansionState: live.favoritesExpansionState,
            linkedFolderWatcher: live.linkedFolderWatcher,
            queryHistoryManager: live.queryHistoryManager,
            dateFormattingService: live.dateFormattingService,
            copilotService: live.copilotService,
            mcpServerManager: live.mcpServerManager,
            syncTracker: fixture.tracker,
            welcomeRouter: WelcomeRouter(appEvents: fixture.appEvents),
            telemetry: live.telemetry,
            projectStorage: fixture.projects
        )
    }

    private func connectionIds(in kind: LibrarySectionKind) -> Set<UUID> {
        func walk(_ nodes: [LibraryNode]) -> [UUID] {
            nodes.flatMap { node -> [UUID] in
                switch node {
                case .connection(let id): return [id]
                case .group(_, let children, _): return walk(children)
                }
            }
        }
        return Set(walk(viewModel.outline.section(kind)?.nodes ?? []))
    }

    @discardableResult
    private func add(
        _ name: String,
        projectId: UUID? = nil,
        groupId: UUID? = nil,
        isFavorite: Bool = false,
        tagIds: [UUID] = []
    ) -> DatabaseConnection {
        var connection = DatabaseConnection(name: name, groupId: groupId, projectId: projectId)
        connection.isFavorite = isFavorite
        connection.tagIds = tagIds
        fixture.connections.addConnection(connection)
        return connection
    }

    // MARK: - Listing

    @Test("A project lists its own connections and groups, and All Connections lists every one")
    func listFollowsTheProject() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let production = try fixture.addGroup("Production", projectId: acme.id)
        let grouped = add("grouped", groupId: production.id)
        let loose = add("loose", projectId: acme.id)
        let outside = add("outside")

        fixture.scope.setActiveProject(acme.id)
        viewModel.loadConnections()

        #expect(connectionIds(in: .connections) == [grouped.id, loose.id])
        #expect(viewModel.activeProjectId == acme.id)
        #expect(viewModel.projects.map(\.id) == [acme.id])
        #expect(viewModel.connections.map(\.id).contains(outside.id))

        fixture.scope.setActiveProject(nil)
        viewModel.loadConnections()

        #expect(connectionIds(in: .connections) == [grouped.id, loose.id, outside.id])
        #expect(viewModel.activeProjectId == nil)
    }

    @Test("Favorites and Recent hold only the active project's connections")
    func favoritesAndRecentFollowTheProject() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let mine = add("mine", projectId: acme.id, isFavorite: true)
        add("other", isFavorite: true)
        let recentMine = add("recent mine", projectId: acme.id)
        let recentOther = add("recent other")
        recents.record(recentMine.id)
        recents.record(recentOther.id)

        fixture.scope.setActiveProject(acme.id)
        viewModel.loadConnections()

        #expect(connectionIds(in: .favorites) == [mine.id])
        #expect(connectionIds(in: .recent) == [recentMine.id])
    }

    @Test("A search inside a project never finds another project's connection")
    func searchFollowsTheProject() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let mine = add("billing primary", projectId: acme.id)
        add("billing replica")
        fixture.scope.setActiveProject(acme.id)
        viewModel.loadConnections()

        viewModel.searchText = "billing"
        viewModel.rebuildOutline()

        #expect(connectionIds(in: .connections) == [mine.id])
    }

    @Test("The tag filter offers the tags used inside the project")
    func tagSuggestionsFollowTheProject() throws {
        let inside = ConnectionTag(name: "inside-\(UUID().uuidString)")
        let elsewhere = ConnectionTag(name: "elsewhere-\(UUID().uuidString)")
        try tags.addTag(inside)
        try tags.addTag(elsewhere)
        let acme = try fixture.projects.createProject(name: "Acme")
        add("mine", projectId: acme.id, tagIds: [inside.id])
        add("other", tagIds: [elsewhere.id])

        viewModel.loadConnections()
        #expect(Set(viewModel.availableTags.map(\.id)) == [inside.id, elsewhere.id])

        fixture.scope.setActiveProject(acme.id)
        viewModel.loadConnections()

        #expect(viewModel.availableTags.map(\.id) == [inside.id])
        #expect(viewModel.suggestedTokens.map(\.id) == [inside.id])
    }

    @Test("A tag token of a tag the project does not use is dropped on a switch")
    func tokenOutsideTheProjectIsDropped() throws {
        let elsewhere = ConnectionTag(name: "elsewhere-\(UUID().uuidString)")
        try tags.addTag(elsewhere)
        let acme = try fixture.projects.createProject(name: "Acme")
        add("mine", projectId: acme.id)
        add("other", tagIds: [elsewhere.id])
        viewModel.loadConnections()
        viewModel.searchTokens = [WelcomeViewModel.token(for: elsewhere)]

        fixture.scope.setActiveProject(acme.id)
        viewModel.loadConnections()

        #expect(viewModel.searchTokens.isEmpty)
        #expect(viewModel.listState == .content)
    }

    // MARK: - Switching

    @Test("A switch reloads the list once the window is set up")
    func switchReloadsTheList() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let mine = add("mine", projectId: acme.id)
        let other = add("other")
        viewModel.setUp()
        #expect(connectionIds(in: .connections) == [mine.id, other.id])

        viewModel.selectProject(acme.id)

        #expect(connectionIds(in: .connections) == [mine.id])
        #expect(viewModel.activeProjectId == acme.id)
    }

    private func makeOutline() -> (WelcomeOutlineCoordinator, WelcomeNSOutlineView, NSScrollView) {
        let coordinator = WelcomeOutlineCoordinator(viewModel: viewModel)
        let outlineView = WelcomeNSOutlineView()
        let scrollView = SidebarOutlineScaffold.makeScrollView(
            outlineView: outlineView,
            configuration: SidebarOutlineScaffold.Configuration(
                columnIdentifier: "WelcomeConnectionColumn",
                allowsMultipleSelection: true,
                rowSizePreference: .matchSystem,
                style: .inset
            )
        )
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        coordinator.attach(outlineView: outlineView)
        return (coordinator, outlineView, scrollView)
    }

    @Test("A switch drops the rows selected in the other project, so Delete and the menu act on listed rows only")
    func switchDropsTheOtherProjectsSelection() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let mine = add("mine", projectId: acme.id)
        let other = add("other")
        viewModel.setUp()
        let (coordinator, outlineView, scrollView) = makeOutline()
        outlineView.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)
        #expect(Set(viewModel.selection) == [
            .connection(mine.id, section: .connections),
            .connection(other.id, section: .connections),
        ])

        viewModel.selectProject(acme.id)
        coordinator.update(revision: viewModel.outlineRevision)

        #expect(viewModel.selection == [.connection(mine.id, section: .connections)])
        #expect(coordinator.selectedRows() == [.connection(mine.id, section: .connections)])
        #expect(coordinator.rows(including: 0) == [.connection(mine.id, section: .connections)])
        _ = scrollView
    }

    @Test("A switch made during a drag reaches the list when the drag ends")
    func switchWaitsForADrag() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        add("mine", projectId: acme.id)
        add("other")
        viewModel.setUp()
        let (coordinator, outlineView, scrollView) = makeOutline()
        #expect(outlineView.numberOfRows == 2)

        coordinator.isDragging = true
        viewModel.selectProject(acme.id)
        coordinator.update(revision: viewModel.outlineRevision)

        #expect(outlineView.numberOfRows == 2)

        coordinator.isDragging = false
        coordinator.applyPendingReloadIfNeeded()

        #expect(outlineView.numberOfRows == 1)
        _ = scrollView
    }

    @Test("A switch made during an inline rename reaches the list when the rename ends")
    func switchWaitsForARename() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        add("mine", projectId: acme.id)
        let other = add("other")
        viewModel.setUp()
        let (coordinator, outlineView, scrollView) = makeOutline()
        #expect(outlineView.numberOfRows == 2)

        coordinator.renameSession = WelcomeRenameSession(
            row: .connection(other.id, section: .connections),
            pendingName: "typed"
        )
        viewModel.selectProject(acme.id)
        coordinator.update(revision: viewModel.outlineRevision)

        #expect(outlineView.numberOfRows == 2)

        coordinator.renameSession = nil
        coordinator.applyPendingReloadIfNeeded()

        #expect(outlineView.numberOfRows == 1)
        _ = scrollView
    }

    @Test("A switch keeps the Recent and the favorites order of the other projects")
    func switchKeepsOtherProjectsDeviceState() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let mine = add("mine", projectId: acme.id, isFavorite: true)
        let other = add("other", isFavorite: true)
        recents.record(mine.id)
        recents.record(other.id)
        preferences.setFavoritesOrder([other.id, mine.id])

        fixture.scope.setActiveProject(acme.id)
        viewModel.loadConnections()

        #expect(recents.lastConnected[other.id] != nil)
        #expect(recents.lastConnected[mine.id] != nil)
        #expect(preferences.favoritesOrder == [other.id, mine.id])
    }

    @Test("An empty project has its own empty state, and a search miss in one names the project")
    func emptyProjectStates() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        add("billing")
        fixture.scope.setActiveProject(acme.id)
        viewModel.loadConnections()

        #expect(viewModel.listState == .emptyProject("Acme"))

        viewModel.searchText = "billing"
        viewModel.rebuildOutline()

        #expect(viewModel.listState == .noProjectSearchMatch("billing", project: "Acme"))
    }

    @Test("Search All Connections leaves the project and keeps the search text")
    func searchAllConnectionsKeepsTheText() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let outside = add("billing")
        viewModel.setUp()
        viewModel.selectProject(acme.id)
        viewModel.searchText = "billing"
        viewModel.rebuildOutline()

        viewModel.searchAllConnections()

        #expect(fixture.scope.activeProjectId == nil)
        #expect(viewModel.searchText == "billing")
        #expect(connectionIds(in: .connections) == [outside.id])
        #expect(viewModel.listState == .content)
    }

    @Test("A project deleted while it is active falls back to All Connections")
    func deletedActiveProjectFallsBack() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let mine = add("mine", projectId: acme.id)
        let other = add("other")
        fixture.scope.setActiveProject(acme.id)
        viewModel.loadConnections()

        try fixture.projects.deleteProject(id: acme.id)
        viewModel.loadConnections()

        #expect(viewModel.activeProjectId == nil)
        #expect(viewModel.projects.isEmpty)
        #expect(connectionIds(in: .connections) == [mine.id, other.id])
    }

    // MARK: - New records

    @Test("A new top-level group lands in the active project, and a subgroup stores none")
    func newGroupLandsInTheActiveProject() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        fixture.scope.setActiveProject(acme.id)
        viewModel.loadConnections()

        try viewModel.createGroup(name: "Production", color: .none, iconName: nil, parentId: nil, moving: [])
        let production = try #require(fixture.groups.loadGroups().first { $0.name == "Production" })
        try viewModel.createGroup(name: "Europe", color: .none, iconName: nil, parentId: production.id, moving: [])
        let europe = try #require(fixture.groups.loadGroups().first { $0.name == "Europe" })

        #expect(production.projectId == acme.id)
        #expect(europe.projectId == nil)
        #expect(Set(viewModel.scopedGroups.map(\.id)) == [production.id, europe.id])
    }

    @Test("New Project from the scope control makes the project and moves the list to it")
    func createProjectSwitchesToIt() throws {
        add("existing")
        viewModel.loadConnections()

        try viewModel.createProject(name: "Acme")

        let acme = try #require(fixture.projects.loadProjects().first)
        #expect(acme.name == "Acme")
        #expect(viewModel.activeProjectId == acme.id)
        #expect(viewModel.listState == .emptyProject("Acme"))
        #expect(throws: ProjectStorageError.duplicateName("acme")) {
            try viewModel.createProject(name: " acme ")
        }
    }

    @Test("The group form offers the project's groups, and every group for one outside it")
    func groupChoices() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let inside = try fixture.addGroup("Inside", projectId: acme.id)
        let outside = try fixture.addGroup("Outside")
        fixture.scope.setActiveProject(acme.id)
        viewModel.loadConnections()

        #expect(viewModel.groupChoices(editing: inside).map(\.id) == [inside.id])
        #expect(Set(viewModel.groupChoices(editing: outside).map(\.id)) == [inside.id, outside.id])
    }

    // MARK: - Export

    @Test("Export All offers the connections of the active project")
    func exportAllFollowsTheProject() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let mine = add("mine", projectId: acme.id)
        add("other")
        fixture.scope.setActiveProject(acme.id)
        viewModel.loadConnections()

        viewModel.handle(.exportConnections)

        guard case .exportConnections(let exported) = viewModel.activeSheet else {
            Issue.record("Export All did not open the export sheet")
            return
        }
        #expect(exported.map(\.id) == [mine.id])
    }

    @Test("Export All in an empty project opens nothing")
    func exportAllInAnEmptyProject() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        add("other")
        fixture.scope.setActiveProject(acme.id)
        viewModel.loadConnections()

        viewModel.handle(.exportConnections)

        #expect(viewModel.activeSheet == nil)
    }

    // MARK: - Move to Project

    @Test("Move to Project moves an ungrouped connection and a top-level group, and undo puts both back")
    func moveToProjectAndUndo() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let globex = try fixture.projects.createProject(name: "Globex")
        let connection = add("loose", projectId: acme.id)
        let group = try fixture.addGroup("Production", projectId: acme.id)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        viewModel.loadConnections()

        undoManager.beginUndoGrouping()
        viewModel.moveToProject(
            connectionIds: [connection.id],
            groupIds: [group.id],
            projectId: globex.id,
            undoManager: undoManager
        )
        undoManager.endUndoGrouping()

        #expect(fixture.stored(connection)?.projectId == globex.id)
        #expect(fixture.groups.group(for: group.id)?.projectId == globex.id)
        #expect(undoManager.undoActionName == String(localized: "Move to Project"))

        undoManager.undo()

        #expect(fixture.stored(connection)?.projectId == acme.id)
        #expect(fixture.groups.group(for: group.id)?.projectId == acme.id)

        undoManager.redo()

        #expect(fixture.stored(connection)?.projectId == globex.id)
        #expect(fixture.groups.group(for: group.id)?.projectId == globex.id)
    }

    @Test("Undo of a group dragged under another project's group gives it back its own project")
    func undoRestoresAProjectLostToAParent() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let globex = try fixture.projects.createProject(name: "Globex")
        let moving = try fixture.addGroup("Staging", projectId: acme.id)
        let parent = try fixture.addGroup("Production", projectId: globex.id)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        viewModel.loadConnections()

        undoManager.beginUndoGrouping()
        viewModel.moveGroups([moving.id], toParent: parent.id, before: nil, undoManager: undoManager)
        undoManager.endUndoGrouping()
        #expect(fixture.groups.group(for: moving.id)?.parentId == parent.id)

        undoManager.undo()

        let restored = try #require(fixture.groups.group(for: moving.id))
        #expect(restored.parentId == nil)
        #expect(restored.projectId == acme.id)
    }

    @Test("A group that clashes with a name in the target project is refused with the store's reason")
    func moveToProjectReportsAClash() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let globex = try fixture.projects.createProject(name: "Globex")
        let moving = try fixture.addGroup("Production", projectId: acme.id)
        try fixture.addGroup("Production", projectId: globex.id)
        viewModel.loadConnections()

        viewModel.moveToProject(connectionIds: [], groupIds: [moving.id], projectId: globex.id, undoManager: nil)

        #expect(viewModel.libraryErrorMessage == GroupStorageError.duplicateName("Production").localizedDescription)
        #expect(fixture.groups.group(for: moving.id)?.projectId == acme.id)
    }

    @Test("A favorites order saved from one project keeps the place of every other project's favorites")
    func scopedFavoritesOrderKeepsOtherProjects() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let globex = try fixture.projects.createProject(name: "Globex")
        let a1 = add("a1", projectId: acme.id, isFavorite: true)
        let a2 = add("a2", projectId: acme.id, isFavorite: true)
        let b1 = add("b1", projectId: globex.id, isFavorite: true)
        let b2 = add("b2", projectId: globex.id, isFavorite: true)
        preferences.setFavoritesOrder([b1.id, a1.id, b2.id, a2.id])
        fixture.scope.setActiveProject(acme.id)
        viewModel.loadConnections()
        let displayed = LibraryOutlineBuilder.favoriteIds(viewModel.outlineRequest(query: LibraryQuery()))
        #expect(displayed == [a1.id, a2.id])

        viewModel.saveFavoritesOrder([a2.id, a1.id], replacing: displayed)
        #expect(preferences.favoritesOrder == [b1.id, a2.id, b2.id, a1.id])

        viewModel.saveFavoritesOrder([a2.id], replacing: [a2.id, a1.id])
        #expect(preferences.favoritesOrder == [b1.id, a2.id, b2.id])

        fixture.scope.setActiveProject(globex.id)
        viewModel.loadConnections()
        #expect(LibraryOutlineBuilder.favoriteIds(viewModel.outlineRequest(query: LibraryQuery())) == [b1.id, b2.id])
    }

    @Test("Reordering and removing a favorite inside a project keeps the other project's order")
    func favoriteEditsInAProjectKeepOtherProjects() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let globex = try fixture.projects.createProject(name: "Globex")
        let a1 = add("a1", projectId: acme.id, isFavorite: true)
        let a2 = add("a2", projectId: acme.id, isFavorite: true)
        let b1 = add("b1", projectId: globex.id, isFavorite: true)
        let b2 = add("b2", projectId: globex.id, isFavorite: true)
        preferences.setFavoritesOrder([b2.id, a1.id, b1.id, a2.id])
        fixture.scope.setActiveProject(acme.id)
        viewModel.loadConnections()

        viewModel.reorderFavorites([a2.id], before: a1.id, undoManager: nil)
        #expect(preferences.favoritesOrder == [b2.id, a2.id, b1.id, a1.id])

        viewModel.setFavorite([a1.id], false, undoManager: nil)
        #expect(preferences.favoritesOrder == [b2.id, a2.id, b1.id])
    }

    @Test("The context menu is given the projects and the active project's groups")
    func menuContextCarriesProjects() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let inside = try fixture.addGroup("Inside", projectId: acme.id)
        try fixture.addGroup("Outside")
        let connection = add("loose", projectId: acme.id)
        fixture.scope.setActiveProject(acme.id)
        viewModel.loadConnections()

        let context = viewModel.menuContext(for: [.connection(connection.id, section: .connections)])

        #expect(context.projects.map(\.id) == [acme.id])
        #expect(context.groups.map(\.id) == [inside.id])
    }

    // MARK: - Scope signal

    @Test("The list follows a switch, a move between projects and a deleted project with no reload asked for")
    func listFollowsTheScopeSignal() throws {
        let acme = try fixture.projects.createProject(name: "Acme")
        let globex = try fixture.projects.createProject(name: "Globex")
        let mine = add("mine", projectId: acme.id)
        let theirs = add("theirs", projectId: globex.id)
        viewModel.setUp()
        viewModel.loadConnections()
        let revision = viewModel.outlineRevision

        fixture.scope.setActiveProject(acme.id)
        #expect(connectionIds(in: .connections) == [mine.id])
        #expect(viewModel.activeProjectId == acme.id)
        #expect(viewModel.outlineRevision > revision)

        #expect(fixture.projects.moveConnections([theirs.id], toProject: acme.id))
        #expect(connectionIds(in: .connections) == [mine.id, theirs.id])

        try fixture.projects.deleteProject(id: acme.id)
        #expect(viewModel.activeProjectId == nil)
        #expect(viewModel.projects.map(\.id) == [globex.id])
        #expect(connectionIds(in: .connections) == [mine.id, theirs.id])
    }
}
