import AppKit
import Foundation
@testable import TablePro
import TableProConnectionLibrary
import TableProPluginKit
import TableProSyncTransport
import TableProTestSupport
import Testing

@MainActor
private final class WelcomeLibraryFixture {
    let viewModel: WelcomeViewModel
    let tags: [ConnectionTag]
    private let suite: EphemeralDefaults
    private let directory: URL

    // Alpha carries "prod" and "eu-west", Beta "prod", Gamma nothing; "unused" is on no connection.
    init() throws {
        suite = try EphemeralDefaults()
        let defaults = suite.defaults
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("welcome-toolbar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let events = AppEvents()
        let tracker = SyncJournalRecorder()
        let connectionStorage = ConnectionStorage(
            fileURL: directory.appendingPathComponent("connections.json"),
            userDefaults: defaults,
            syncJournal: tracker.journal
        )
        let groupStorage = GroupStorage(userDefaults: defaults, syncJournal: tracker.journal, connectionStorage: connectionStorage)
        let tagStorage = TagStorage(userDefaults: defaults, syncJournal: tracker.journal, appEvents: events)
        let prod = ConnectionTag(name: "prod", color: .red)
        let euWest = ConnectionTag(name: "eu-west", color: .blue)
        let unused = ConnectionTag(name: "unused-prod", color: .gray)
        for tag in [prod, euWest, unused] {
            try tagStorage.addTag(tag)
        }
        tags = [prod, euWest, unused]

        var alpha = DatabaseConnection(name: "Alpha", type: .mysql, sortOrder: 0)
        alpha.tagIds = [prod.id, euWest.id]
        var beta = DatabaseConnection(name: "Beta", type: .postgresql, sortOrder: 1)
        beta.tagIds = [prod.id]
        let gamma = DatabaseConnection(name: "Gamma", type: .mysql, sortOrder: 2)
        #expect(connectionStorage.saveConnections([alpha, beta, gamma]))

        let live = AppServices.live
        let services = AppServices(
            appEvents: events,
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
            tableFolderStorage: live.tableFolderStorage,
            aiChatStorage: live.aiChatStorage,
            aiKeyStorage: live.aiKeyStorage,
            aiAccessApprovals: live.aiAccessApprovals,
            groupStorage: groupStorage,
            tagStorage: tagStorage,
            sshProfileStorage: live.sshProfileStorage,
            credentialProfileStorage: live.credentialProfileStorage,
            featureAccess: live.featureAccess,
            favoritesExpansionState: live.favoritesExpansionState,
            linkedFolderWatcher: live.linkedFolderWatcher,
            queryHistoryManager: live.queryHistoryManager,
            dateFormattingService: live.dateFormattingService,
            copilotService: live.copilotService,
            mcpServerManager: live.mcpServerManager,
            syncJournal: tracker.journal,
            welcomeRouter: WelcomeRouter(),
            telemetry: live.telemetry
        )
        viewModel = WelcomeViewModel(
            services: services,
            importableAppDetector: { false },
            groupExpansionStore: WelcomeGroupExpansionStore(defaults: defaults),
            recentConnections: RecentConnectionsStore(defaults: defaults, appEvents: events),
            listPreferences: ConnectionListPreferences(defaults: defaults, appEvents: events)
        )
        viewModel.loadConnections()
    }

    var prod: ConnectionTag { tags[0] }
    var euWest: ConnectionTag { tags[1] }
    var unused: ConnectionTag { tags[2] }

    isolated deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class RecordingOutline: WelcomeOutlineControlling {
    var focusRequests: [Bool] = []
    var onFocus: (() -> Void)?
    var outlineUndoManager: UndoManager? { nil }
    func beginRename(_ row: LibraryRowID) {}
    func focusList(selectFirstRow: Bool) {
        focusRequests.append(selectFirstRow)
        onFocus?()
    }
}

@MainActor
struct WelcomeToolbarTests {
    private let fixture: WelcomeLibraryFixture
    private let window: NSWindow
    private let controller: WelcomeToolbarController

    init() throws {
        fixture = try WelcomeLibraryFixture()
        window = WelcomeWindowController.makeWelcomeWindow()
        controller = WelcomeToolbarController(viewModel: fixture.viewModel)
        controller.install(in: window)
    }

    private func item(_ identifier: NSToolbarItem.Identifier) throws -> NSToolbarItem {
        try #require(window.toolbar?.items.first { $0.itemIdentifier == identifier })
    }

    private func viewOptionsMenu() throws -> NSMenu {
        let menu = try #require((try item(.welcomeViewOptions) as? NSMenuToolbarItem)?.menu)
        controller.menuNeedsUpdate(menu)
        return menu
    }

    private func choose(_ title: String, in menu: NSMenu) throws {
        let index = menu.indexOfItem(withTitle: title)
        try #require(index >= 0, "View Options has no \(title)")
        menu.performActionForItem(at: index)
    }

    @Test("The window's toolbar is AppKit's own, fixed at Icon Only")
    func toolbarIsFixedAtIconOnly() throws {
        let toolbar = try #require(window.toolbar)
        #expect(toolbar.identifier == WelcomeToolbarController.toolbarIdentifier)
        #expect(toolbar.delegate === controller)
        #expect(window.toolbarStyle == .unified)
        #expect(toolbar.displayMode == .iconOnly)
        #expect(!toolbar.allowsUserCustomization)
        #expect(!toolbar.autosavesConfiguration)
        if #available(macOS 15.0, *) {
            #expect(!toolbar.allowsDisplayModeCustomization)
        }
    }

    @Test("The buttons lead the list pane and search trails it, as they did")
    func itemsKeepTheirPlaces() throws {
        let identifiers = try #require(window.toolbar).items.map { $0.itemIdentifier }
        #expect(identifiers == [
            .sidebarTrackingSeparator, .welcomeNewConnection, .welcomeNewGroup, .welcomeViewOptions, .flexibleSpace,
            .welcomeSearch,
        ])
    }

    @Test("Each item names itself, which is what VoiceOver and UI tests read")
    func itemsNameThemselves() throws {
        #expect(try item(.welcomeNewConnection).label == "New Connection")
        #expect(try item(.welcomeNewConnection).toolTip?.hasPrefix("New Connection") == true)
        #expect(try item(.welcomeNewGroup).label == "New Group")
        let viewOptions = try #require(try item(.welcomeViewOptions) as? NSMenuToolbarItem)
        #expect(viewOptions.label == "View Options")
        #expect(viewOptions.showsIndicator)
        let search = try #require(try item(.welcomeSearch) as? NSSearchToolbarItem)
        #expect(search.searchField.placeholderString == "Search Connections")
        #expect(search.searchField.accessibilityIdentifier() == "welcome-toolbar-search")
    }

    @Test("View Options sorts, and lists only the tags a connection carries")
    func viewOptionsSortsAndListsUsedTags() throws {
        let menu = try viewOptionsMenu()
        let titles = menu.items.filter { !$0.isSeparatorItem }.map { $0.title }
        #expect(titles == ["Sort By", "Manual", "Name", "Database Type", "Last Connected", "Filter by Tag", "prod", "eu-west"])
        #expect(!titles.contains("Match"))
        #expect(!titles.contains("Clear Filters"))

        try choose("Name", in: menu)

        #expect(fixture.viewModel.sortMode == .name)
        let reopened = try viewOptionsMenu()
        #expect(reopened.item(withTitle: "Name")?.state == .on)
        #expect(reopened.item(withTitle: "Manual")?.state == .off)
    }

    @Test("Two tags from View Options add Match and Clear Filters, and fill the glyph")
    func viewOptionsFiltersByTag() throws {
        #expect(controller.viewOptionsSymbol == ToolbarSymbols.filter(isActive: false))

        try choose("prod", in: try viewOptionsMenu())
        try choose("eu-west", in: try viewOptionsMenu())

        #expect(fixture.viewModel.tagFilterIds == [fixture.prod.id, fixture.euWest.id])
        #expect(controller.viewOptionsSymbol == ToolbarSymbols.filter(isActive: true))
        let menu = try viewOptionsMenu()
        #expect(menu.item(withTitle: "prod")?.state == .on)
        #expect(menu.item(withTitle: "Any Selected Tag")?.state == .on)

        try choose("All Selected Tags", in: menu)
        #expect(fixture.viewModel.tagMatch == .all)

        try choose("Clear Filters", in: try viewOptionsMenu())
        #expect(fixture.viewModel.tagFilterIds.isEmpty)
        #expect(controller.viewOptionsSymbol == ToolbarSymbols.filter(isActive: false))
    }

    @Test("Typing sets the query, and a query the model clears empties the field")
    func searchFieldFollowsTheQuery() throws {
        let field = try #require(try item(.welcomeSearch) as? NSSearchToolbarItem).searchField
        field.stringValue = "alp"
        field.sendAction(field.action, to: field.target)
        #expect(fixture.viewModel.searchText == "alp")

        fixture.viewModel.searchText = ""

        #expect(field.stringValue.isEmpty)
    }

    @Test("Return in the search field hands the keyboard to the list, first row selected")
    func returnFocusesTheList() throws {
        let outline = RecordingOutline()
        fixture.viewModel.outlineController = outline
        let field = try #require(try item(.welcomeSearch) as? NSSearchToolbarItem).searchField

        #expect(controller.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(!controller.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))))

        #expect(outline.focusRequests == [true])
    }

    @Test("Return acts on everything typed, even while the search debounce is still pending")
    func returnActsOnTheWholeQuery() throws {
        let viewModel = fixture.viewModel
        let outline = RecordingOutline()
        viewModel.outlineController = outline
        var namesAtFocus: [String] = []
        outline.onFocus = {
            namesAtFocus = viewModel.outline.connectionIds(in: .connections).compactMap { viewModel.connectionsById[$0]?.name }
        }
        let field = try #require(try item(.welcomeSearch) as? NSSearchToolbarItem).searchField

        // "g" rebuilds at once and keeps Beta (PostgreSQL) and Gamma; "ga" waits for the debounce.
        viewModel.searchText = "g"
        viewModel.searchText = "ga"
        #expect(controller.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))

        #expect(namesAtFocus == ["Gamma"])
    }
}

@MainActor
struct WelcomeOutlineFocusTests {
    private let fixture: WelcomeLibraryFixture

    init() throws {
        fixture = try WelcomeLibraryFixture()
    }

    @Test("Picking the first row reads the current outline, not the one SwiftUI has yet to hand over")
    func focusPicksFromTheCurrentOutline() throws {
        let viewModel = fixture.viewModel
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        defer { window.orderOut(nil) }
        let coordinator = WelcomeOutlineCoordinator(viewModel: viewModel)
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        coordinator.attach(outlineView: outlineView)
        let beta = try #require(viewModel.connections.first { $0.name == "Beta" })

        // Only Beta's name holds a "b"; the outline view still lists all three until a revision reaches it.
        viewModel.searchText = "b"
        viewModel.submitSearch()

        #expect(coordinator.selectedRows() == [.connection(beta.id, section: .connections)])
        #expect(window.firstResponder === outlineView)
    }
}

@MainActor
struct WelcomeTagSuggestionsTests {
    private let fixture: WelcomeLibraryFixture

    init() throws {
        fixture = try WelcomeLibraryFixture()
    }

    @available(macOS 15.0, *)
    @Test("Typing offers the used tags whose name contains the text, and nothing for no text")
    func suggestsMatchingUsedTags() throws {
        let suggestions = WelcomeTagSuggestions(viewModel: fixture.viewModel)

        let response = suggestions.suggestions(for: "PRO")

        #expect(response.itemSections.map(\.title) == ["Tags"])
        #expect(response.itemSections.flatMap(\.items).map(\.title) == ["prod"])
        #expect(suggestions.suggestions(for: "  ").itemSections.isEmpty)
    }

    @available(macOS 15.0, *)
    @Test("A tag already filtering is not offered again")
    func skipsActiveTags() throws {
        fixture.viewModel.setTagFilter(fixture.prod.id, isOn: true)

        let titles = WelcomeTagSuggestions(viewModel: fixture.viewModel).suggestions(for: "e")
            .itemSections.flatMap(\.items).map(\.title)

        #expect(titles == ["eu-west"])
    }

    @available(macOS 15.0, *)
    @Test("Choosing a suggestion filters by the tag and clears the typed text")
    func choosingASuggestionFilters() throws {
        let suggestions = WelcomeTagSuggestions(viewModel: fixture.viewModel)
        fixture.viewModel.searchText = "pro"
        let item = try #require(suggestions.suggestions(for: "pro").itemSections.first?.items.first)

        suggestions.textField(NSSearchField(), didSelect: item)

        #expect(fixture.viewModel.tagFilterIds == [fixture.prod.id])
        #expect(fixture.viewModel.searchText.isEmpty)
        #expect(suggestions.textField(NSSearchField(), textCompletionFor: item) == nil)
    }
}

@MainActor
struct WelcomeTagFilterBarTests {
    private let fixture: WelcomeLibraryFixture

    init() throws {
        fixture = try WelcomeLibraryFixture()
    }

    private func bar() -> WelcomeTagFilterBar {
        let bar = WelcomeTagFilterBar(viewModel: fixture.viewModel)
        bar.apply(fixture.viewModel.tagFilter)
        return bar
    }

    @Test("The filter names its tags from storage, in the order they were turned on")
    func filterFollowsTheOrderTagsWereTurnedOn() {
        fixture.viewModel.setTagFilter(fixture.euWest.id, isOn: true)
        fixture.viewModel.setTagFilter(fixture.prod.id, isOn: true)

        let filter = fixture.viewModel.tagFilter
        let names = filter.tags.map(\.name)
        #expect(names == ["eu-west", "prod"])
        #expect(filter.isActive)
        #expect(filter.offersMatch)
    }

    @Test("One toggle per active tag, all on, with Any or All once two are on")
    func oneTogglePerTag() {
        fixture.viewModel.setTagFilter(fixture.prod.id, isOn: true)
        let single = bar()
        let singleTitles = single.tagButtons.map { $0.title }
        #expect(singleTitles == ["prod"])
        #expect(single.matchPopUp == nil)
        #expect(single.clearButton.title == "Clear Filters")

        fixture.viewModel.setTagFilter(fixture.euWest.id, isOn: true)
        let both = bar()
        let bothTitles = both.tagButtons.map { $0.title }
        #expect(bothTitles == ["prod", "eu-west"])
        #expect(both.tagButtons.allSatisfy { $0.state == .on })
        let labels = both.tagButtons.map { $0.accessibilityLabel() }
        #expect(labels == ["prod", "eu-west"])
        #expect(both.matchPopUp?.titleOfSelectedItem == "Any Selected Tag")
    }

    @Test("Clicking a tag stops filtering by that tag alone")
    func clickingATagRemovesIt() throws {
        fixture.viewModel.setTagFilter(fixture.prod.id, isOn: true)
        fixture.viewModel.setTagFilter(fixture.euWest.id, isOn: true)

        try #require(bar().tagButtons.first).performClick(nil)

        #expect(fixture.viewModel.tagFilterIds == [fixture.euWest.id])
    }

    @Test("The match pop-up and Clear Filters reach the model")
    func matchAndClearReachTheModel() throws {
        fixture.viewModel.setTagFilter(fixture.prod.id, isOn: true)
        fixture.viewModel.setTagFilter(fixture.euWest.id, isOn: true)
        let bar = bar()
        let popUp = try #require(bar.matchPopUp)

        popUp.selectItem(withTitle: "All Selected Tags")
        popUp.sendAction(popUp.action, to: popUp.target)
        #expect(fixture.viewModel.tagMatch == .all)

        bar.clearButton.performClick(nil)
        #expect(fixture.viewModel.tagFilterIds.isEmpty)
    }

    @Test("The bar exists only while a tag filters the list")
    func barComesAndGoesWithTheFilter() throws {
        let split = WelcomeSplitViewController(viewModel: fixture.viewModel)
        _ = split.view
        let listItem = try #require(split.splitViewItems.last)
        #expect(split.tagFilterBar == nil)

        fixture.viewModel.setTagFilter(fixture.prod.id, isOn: true)
        let bar = try #require(split.tagFilterBar)
        if #available(macOS 26.0, *) {
            let accessories = listItem.topAlignedAccessoryViewControllers
            #expect(accessories.count == 1)
            #expect(accessories.first?.view === bar)
        } else {
            #expect(bar.superview != nil)
        }

        fixture.viewModel.clearTagFilters()
        #expect(split.tagFilterBar == nil)
        if #available(macOS 26.0, *) {
            #expect(listItem.topAlignedAccessoryViewControllers.isEmpty)
        }
    }
}
