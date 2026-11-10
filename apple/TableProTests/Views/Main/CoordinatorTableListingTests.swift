//
//  CoordinatorTableListingTests.swift
//  TableProTests
//

import Combine
import Foundation
import TableProTestSupport
import Testing

@testable import TablePro

private struct ObjectListRead: Equatable {
    let category: SidebarObjectCategory
    let rereading: Bool
}

/// Answers every kind with nothing and records each read, so a case sees which read a model made.
@MainActor
private final class RecordingObjectSource: CatalogObjectListSource {
    private(set) var reads: [ObjectListRead] = []

    func objects(
        _ category: SidebarObjectCategory,
        in scope: DatabaseScope,
        rereading: Bool
    ) async -> MetadataFetchOutcome<CatalogObjectList> {
        reads.append(ObjectListRead(category: category, rereading: rereading))
        return .fetched(category == .table ? .relations([]) : .routines([]))
    }

    func objectListChanges(_ category: SidebarObjectCategory, in scope: DatabaseScope) -> AnyPublisher<CatalogObjectList, Never> {
        Empty().eraseToAnyPublisher()
    }
}

/// Show All Tables used to open the listing statement in an editor tab, "Query 1", that nothing ran.
@MainActor
struct CoordinatorTableListingTests {
    private func makeCoordinator() -> (MainContentCoordinator, QueryTabManager, PayloadLog) {
        let connection = TestFixtures.makeConnection(database: "shop", type: .mysql)
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        let log = PayloadLog()
        coordinator.openTabInNewWindow = { log.payloads.append($0) }
        return (coordinator, tabManager, log)
    }

    private final class PayloadLog {
        var payloads: [EditorTabPayload] = []
    }

    @Test("Show All Tables opens a read-only listing tab, not a query editor")
    func opensAListingTab() throws {
        let (coordinator, tabManager, log) = makeCoordinator()
        defer { coordinator.teardown() }

        coordinator.showBrowsedObjects(.table)

        let tab = try #require(tabManager.selectedTab)
        #expect(tab.tabType == .tableListing)
        #expect(tab.title == String(localized: "Objects"))
        #expect(tab.tableContext.databaseName == coordinator.browseDatabaseName)
        #expect(tab.tableContext.isEditable == false)
        #expect(tab.content.query.isEmpty)
        #expect(log.payloads.isEmpty)
        #expect(!tabManager.tabs.contains { $0.tabType == .query })
    }

    @Test("Opening it again returns to the same tab and refreshes it")
    func secondOpenReusesAndRefreshes() throws {
        let (coordinator, tabManager, _) = makeCoordinator()
        defer { coordinator.teardown() }
        var refreshed: [UUID] = []
        let subscription = AppEvents.shared.tabRefreshRequested.sink { refreshed.append($0) }
        defer { subscription.cancel() }

        coordinator.showBrowsedObjects(.table)
        let first = try #require(tabManager.selectedTabId)
        tabManager.addTab(initialQuery: "SELECT 1", databaseName: "shop")
        coordinator.showBrowsedObjects(.table)

        #expect(tabManager.selectedTabId == first)
        #expect(tabManager.tabs.filter { $0.tabType == .tableListing }.count == 1)
        #expect(refreshed == [first, first])
    }

    @Test("Refresh on a listing tab reloads that listing")
    func refreshReloadsTheListing() throws {
        let (coordinator, tabManager, _) = makeCoordinator()
        defer { coordinator.teardown() }
        coordinator.showBrowsedObjects(.table)
        let id = try #require(tabManager.selectedTabId)
        var refreshed: [UUID] = []
        let subscription = AppEvents.shared.tabRefreshRequested.sink { refreshed.append($0) }
        defer { subscription.cancel() }

        coordinator.handleRefresh(hasPendingTableOps: false, onDiscard: {})

        #expect(refreshed == [id])
    }

    private func group(_ database: String, _ kind: SidebarObjectKind = .table) -> DatabaseTreeObjectGroup {
        DatabaseTreeObjectGroup(database: database, schema: nil, kind: kind)
    }

    @Test("Show Objects opens the clicked container and kind, not the browsed one, to keep")
    func showObjectsOpensTheClickedContainer() throws {
        let (coordinator, tabManager, _) = makeCoordinator()
        defer { coordinator.teardown() }

        coordinator.showObjects(group("archive", .view), asPreview: false)

        let tab = try #require(tabManager.selectedTab)
        #expect(tab.tabType == .tableListing)
        #expect(tab.tableContext.databaseName == "archive")
        #expect(tab.display.listingKind == .view)
        #expect(tab.title == String(localized: "Objects"))
        #expect(!tab.isPreview)
    }

    @Test("A selection previews a container's objects, and the next selection takes the preview's place")
    func selectionPreviewsAndReplaces() throws {
        let (coordinator, tabManager, _) = makeCoordinator()
        defer { coordinator.teardown() }
        tabManager.addTab(initialQuery: "SELECT 1", databaseName: "shop")
        let kept = try #require(tabManager.selectedTabId)

        coordinator.showObjects(group("shop"), asPreview: true)
        let preview = try #require(tabManager.selectedTab)
        coordinator.showObjects(group("archive", .function), asPreview: true)

        let replacement = try #require(tabManager.selectedTab)
        #expect(preview.isPreview)
        #expect(replacement.id != preview.id)
        #expect(tabManager.tabs.map(\.id) == [kept, replacement.id])
        #expect(replacement.isPreview)
        #expect(replacement.tableContext.databaseName == "archive")
        #expect(replacement.display.listingKind == .function)
    }

    @Test("A selection on a container whose objects are open retargets that tab and leaves it a preview")
    func selectionRetargetsTheContainersTab() throws {
        let (coordinator, tabManager, _) = makeCoordinator()
        defer { coordinator.teardown() }
        coordinator.showObjects(group("shop"), asPreview: true)
        let id = try #require(tabManager.selectedTabId)

        coordinator.showObjects(group("shop", .trigger), asPreview: true)

        #expect(tabManager.tabs.map(\.id) == [id])
        #expect(tabManager.selectedTab?.display.listingKind == .trigger)
        #expect(tabManager.selectedTab?.isPreview == true)
    }

    @Test("A table preview gives its place to the objects a selection opens")
    func tablePreviewGivesWay() throws {
        let (coordinator, tabManager, _) = makeCoordinator()
        defer { coordinator.teardown() }
        try tabManager.addTableTab(tableName: "orders", databaseType: .mysql, databaseName: "shop", isPreview: true)
        let table = try #require(tabManager.selectedTabId)

        coordinator.showObjects(group("shop"), asPreview: true)

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.selectedTab?.tabType == .tableListing)
        #expect(tabManager.selectedTabId != table)
    }

    @Test("A selection never replaces a tab the user kept")
    func keptTabsStay() throws {
        let (coordinator, tabManager, _) = makeCoordinator()
        defer { coordinator.teardown() }
        coordinator.showObjects(group("shop"), asPreview: false)

        coordinator.showObjects(group("archive"), asPreview: true)

        #expect(tabManager.tabs.count == 2)
    }

    @Test("A selection of another kind in a kept listing's container previews it beside the kept tab")
    func selectionBesideAKeptListingLeavesItAlone() throws {
        let (coordinator, tabManager, _) = makeCoordinator()
        defer { coordinator.teardown() }
        coordinator.showObjects(group("shop"), asPreview: false)
        let kept = try #require(tabManager.selectedTabId)

        coordinator.showObjects(group("shop", .view), asPreview: true)

        let preview = try #require(tabManager.selectedTab)
        let keptTab = try #require(tabManager.tabs.first { $0.id == kept })
        #expect(tabManager.tabs.map(\.id) == [kept, preview.id])
        #expect(preview.isPreview)
        #expect(preview.display.listingKind == .view)
        #expect(keptTab.display.listingKind == nil)
        #expect(keptTab.title == String(localized: "Objects"))
        #expect(!keptTab.isPreview)
    }

    @Test("A selection of the kind a kept listing shows returns to it")
    func selectionReturnsToTheKeptListing() throws {
        let (coordinator, tabManager, _) = makeCoordinator()
        defer { coordinator.teardown() }
        coordinator.showObjects(group("shop", .view), asPreview: false)
        let kept = try #require(tabManager.selectedTabId)
        tabManager.addTab(initialQuery: "SELECT 1", databaseName: "shop")

        coordinator.showObjects(group("shop", .view), asPreview: true)

        #expect(tabManager.selectedTabId == kept)
        #expect(tabManager.tabs.filter { $0.tabType == .tableListing }.count == 1)
        #expect(tabManager.selectedTab?.isPreview == false)
    }

    @Test("Show Objects retargets the kept listing, closes the preview beside it and refreshes the kept one")
    func showObjectsTakesTheKeptListing() throws {
        let (coordinator, tabManager, _) = makeCoordinator()
        defer { coordinator.teardown() }
        coordinator.showObjects(group("shop"), asPreview: false)
        let kept = try #require(tabManager.selectedTabId)
        coordinator.showObjects(group("shop", .view), asPreview: true)
        var refreshed: [UUID] = []
        let subscription = AppEvents.shared.tabRefreshRequested.sink { refreshed.append($0) }
        defer { subscription.cancel() }

        coordinator.showObjects(group("shop", .function), asPreview: false)

        #expect(tabManager.tabs.map(\.id) == [kept])
        #expect(tabManager.selectedTab?.display.listingKind == .function)
        #expect(tabManager.selectedTab?.isPreview == false)
        #expect(refreshed == [kept])
    }

    /// What the view hands the store when it draws the tab, with reads that go to `source`.
    private func drawnModel(
        _ coordinator: MainContentCoordinator,
        tab tabId: UUID,
        _ target: DatabaseTreeObjectGroup,
        source: RecordingObjectSource
    ) -> TableListingViewModel {
        coordinator.tableListingModels.model(forTab: tabId, target: target) {
            TableListingViewModel(
                tabId: tabId,
                scope: DatabaseScope(connectionId: coordinator.connectionId, database: target.database, schema: target.schema),
                kind: target.kind,
                loader: TableListingLoader(databaseType: .mysql, slot: .database),
                objectSource: source
            )
        }
    }

    /// The view draws a retargeted tab's new model only after Show Objects returns, so the refresh it
    /// sent reached the model being replaced, and the new kind showed the sidebar's list unread.
    @Test("Show Objects of another kind on an open tab reads the new kind again, and the old kind's model takes no refresh")
    func showObjectsRereadsTheNewKind() async throws {
        let (coordinator, tabManager, _) = makeCoordinator()
        defer { coordinator.teardown() }
        let source = RecordingObjectSource()
        coordinator.showObjects(group("shop", .view), asPreview: false)
        let id = try #require(tabManager.selectedTabId)
        let views = drawnModel(coordinator, tab: id, group("shop", .view), source: source)
        await views.loadIfNeeded()?.value

        coordinator.showObjects(group("shop", .function), asPreview: false)
        #expect(!views.isRefreshing)
        let functions = drawnModel(coordinator, tab: id, group("shop", .function), source: source)
        await functions.loadIfNeeded()?.value

        #expect(functions !== views)
        #expect(source.reads == [
            ObjectListRead(category: .table, rereading: false),
            ObjectListRead(category: .routine, rereading: true),
        ])
    }

    @Test("Picking another kind takes the sidebar's list, as a tab opened fresh does")
    func pickingAKindTakesTheSidebarsList() async throws {
        let (coordinator, tabManager, _) = makeCoordinator()
        defer { coordinator.teardown() }
        let source = RecordingObjectSource()
        coordinator.showObjects(group("shop", .view), asPreview: false)
        let id = try #require(tabManager.selectedTabId)
        await drawnModel(coordinator, tab: id, group("shop", .view), source: source).loadIfNeeded()?.value

        coordinator.selectListingKind(.function, inTab: id)
        await drawnModel(coordinator, tab: id, group("shop", .function), source: source).loadIfNeeded()?.value

        #expect(source.reads == [
            ObjectListRead(category: .table, rereading: false),
            ObjectListRead(category: .routine, rereading: false),
        ])
    }

    @Test("Picking a kind retargets the tab, keeps its Objects title and keeps the preview")
    func pickingAKindKeepsThePreview() throws {
        let (coordinator, tabManager, _) = makeCoordinator()
        defer { coordinator.teardown() }
        coordinator.showObjects(group("shop"), asPreview: true)
        let id = try #require(tabManager.selectedTabId)

        coordinator.selectListingKind(.view, inTab: id)

        let tab = try #require(tabManager.selectedTab)
        #expect(tab.id == id)
        #expect(tab.display.listingKind == .view)
        #expect(tab.title == String(localized: "Objects"))
        #expect(!tab.isPreview)
    }

    @Test("Falling back to Tables keeps the Objects title and leaves a preview a preview")
    func fallbackKeepsThePreview() throws {
        let (coordinator, tabManager, _) = makeCoordinator()
        defer { coordinator.teardown() }
        coordinator.showObjects(group("shop", .function), asPreview: true)
        let id = try #require(tabManager.selectedTabId)

        coordinator.adoptListingKind(.table, inTab: id)

        let tab = try #require(tabManager.selectedTab)
        #expect(tab.display.listingKind == nil)
        #expect(tab.title == String(localized: "Objects"))
        #expect(tab.isPreview)
    }

    @Test("A row opens its table in the listing's own database as a kept tab, and keeps the listing")
    func rowOpensItsTableInTheListingsDatabase() throws {
        let (coordinator, tabManager, log) = makeCoordinator()
        defer { coordinator.teardown() }
        coordinator.showObjects(group("archive"), asPreview: true)
        let listing = try #require(tabManager.selectedTabId)

        coordinator.performListingAction(.open(.relation(name: "orders", schema: nil, type: .table)), fromTab: listing)

        let payload = try #require(log.payloads.last)
        #expect(payload.tableName == "orders")
        #expect(payload.databaseName == "archive")
        #expect(!payload.isPreview)
        #expect(tabManager.tabs.first { $0.id == listing }?.isPreview == false)
    }

    // MARK: - Tool strip

    @Test("The strip's drops and exports name the listing's own database, and only its relations")
    func stripRefsNameTheListingsDatabase() throws {
        let (coordinator, tabManager, _) = makeCoordinator()
        defer { coordinator.teardown() }
        coordinator.showObjects(group("archive"), asPreview: false)
        let tab = try #require(tabManager.selectedTab)

        let refs = coordinator.listingTableRefs([
            .relation(name: "orders", schema: nil, type: .table),
            .sourced(DatabaseObjectRef(kind: .function, name: "touch", database: "archive", schema: nil)),
        ], in: tab)

        #expect(refs.count == 1)
        #expect(refs.first?.database == "archive")
        #expect(refs.first?.table.name == "orders")
        #expect(refs.first?.table.type == .table)
    }

    @Test("A read-only connection's strip offers no write")
    func readOnlyOffersNoWrite() throws {
        let (coordinator, tabManager, _) = makeCoordinator()
        defer { coordinator.teardown() }
        coordinator.toolbarState.safeModeLevel = .readOnly
        coordinator.showObjects(group("shop"), asPreview: false)
        let id = try #require(tabManager.selectedTabId)

        let facts = coordinator.listingCommandFacts(for: [.relation(name: "orders", schema: nil, type: .table)], inTab: id)

        #expect(facts == ObjectListingCommandFacts(isReadOnly: true))
    }

    @Test("New Table on a connection whose driver cannot create one opens nothing")
    func createTableNeedsADriverThatCreates() throws {
        let (coordinator, tabManager, log) = makeCoordinator()
        defer { coordinator.teardown() }
        coordinator.showObjects(group("archive"), asPreview: false)
        let listing = try #require(tabManager.selectedTabId)

        coordinator.performListingAction(.createTable, fromTab: listing)

        #expect(log.payloads.isEmpty)
        #expect(tabManager.tabs.count == 1)
    }

    // MARK: - The browse cursor

    /// Each database is an entry of its own on the strip, so a listing tab names the entry it shows in.
    private func withConnectedCoordinator(
        _ body: (MainContentCoordinator, QueryTabManager) async throws -> Void
    ) async throws {
        let connection = TestFixtures.makeConnection(database: "shop", type: .mysql)
        let driver = PluginDriverAdapter(connection: connection, pluginDriver: SwitchingDriverStub())
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let tabManager = QueryTabManager(containerTarget: .database, visibleContainer: "shop")
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        try await body(coordinator, tabManager)
    }

    @Test("A selection in the browsed database leaves the browse cursor where it is")
    func selectionInTheBrowsedContainerKeepsTheCursor() async throws {
        try await withConnectedCoordinator { coordinator, tabManager in
            #expect(coordinator.browseCursorCoordinator.browsedContainer == "shop")

            coordinator.showObjects(group("shop", .view), asPreview: true)

            #expect(tabManager.selectedTab?.tabType == .tableListing)
            #expect(tabManager.selectedTab?.tableContext.databaseName == "shop")
            #expect(tabManager.visibleContainer == "shop")
            #expect(coordinator.browseCursorCoordinator.pendingRequest == nil)
            #expect(coordinator.browseCursorCoordinator.browsedContainer == "shop")
        }
    }

    /// Accepted: tabs are per database, so showing another database's objects shows its entry, and
    /// the connection follows the entry on screen.
    @Test("A selection in another database takes the browse cursor there")
    func selectionInAnotherContainerMovesTheCursor() async throws {
        try await withConnectedCoordinator { coordinator, tabManager in
            coordinator.showObjects(group("archive", .view), asPreview: true)

            #expect(tabManager.selectedTab?.tableContext.databaseName == "archive")
            #expect(tabManager.visibleContainer == "archive")
            try await waitUntil { coordinator.browseCursorCoordinator.browsedContainer == "archive" }
            #expect(coordinator.browseCursorCoordinator.pendingRequest == nil)
        }
    }
}
