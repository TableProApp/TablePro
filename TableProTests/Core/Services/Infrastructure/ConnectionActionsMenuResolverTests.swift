//
//  ConnectionActionsMenuResolverTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

struct ConnectionActionsMenuResolverTests {
    private static let tabKinds: [TabType] = [
        .query, .table, .createTable, .erDiagram, .serverDashboard, .usersRoles, .insights, .objectSource,
    ]

    /// Every title the pull-down may use, and every one of them is a title the menu bar already
    /// carries. The rule this pins is that the pull-down is a second route to commands that exist,
    /// never a place for commands that exist nowhere else: a menu nobody can find from the menu bar
    /// is a menu that cannot be searched, rebound or discovered.
    private static let menuBarTitles: Set<String> = [
        String(localized: "New Session"),
        String(localized: "Open Session"),
        String(localized: "Close Session"),
        String(localized: "Delete Session…"),
        String(localized: "New Conversation"),
        String(localized: "Add Row"),
        String(localized: "Restore Previous Values…"),
        String(localized: "Back"),
        String(localized: "Forward"),
        String(localized: "Preview SQL"),
        String(localized: "Show Results"),
        String(localized: "Export Results…"),
        String(localized: "Export Tables…"),
        String(localized: "Import Data…"),
        String(localized: "Import Data From"),
        String(localized: "Show DDL"),
        String(localized: "Copy DDL"),
        String(localized: "Show Query History"),
        String(localized: "Users & Roles"),
        String(localized: "Query Insights"),
        String(localized: "Server Dashboard"),
        String(localized: "New Tab"),
        String(localized: "Open Quickly…"),
        String(localized: "Mode"),
        String(localized: "Switch Connection…"),
        String(localized: "Reconnect"),
        String(localized: "Close Connection"),
    ]

    private static func context(
        tabKind: TabType? = .table,
        resultsMode: ResultsViewMode? = .data,
        contentMode: ConnectionWorkspaceContentMode = .browse,
        isConnected: Bool = true,
        supportsImport: Bool = true,
        supportsServerDashboard: Bool = true,
        isAIEnabled: Bool = true
    ) -> ToolbarContext {
        ToolbarContext(
            tabKind: tabKind,
            resultsMode: resultsMode,
            contentMode: contentMode,
            pane: isConnected ? .content : .unavailable(.notConnected),
            isConnected: isConnected,
            hasSelectedWorkspace: true,
            supportsImport: supportsImport,
            supportsServerDashboard: supportsServerDashboard,
            isAIEnabled: isAIEnabled
        )
    }

    private static func entries(_ context: ToolbarContext) -> [ActionsMenuEntry] {
        ConnectionActionsMenuResolver.sections(context).flatMap(\.entries)
    }

    private static func titles(_ context: ToolbarContext) -> [String] {
        entries(context).map(\.title)
    }

    // MARK: - House rules

    @Test("Every entry the pull-down can emit has a menu-bar twin with the same title")
    func everyEntryHasAMenuBarTwin() {
        for tabKind in Self.tabKinds + [nil] {
            for contentMode in ConnectionWorkspaceContentMode.allCases {
                for isConnected in [true, false] {
                    for title in Self.titles(
                        Self.context(tabKind: tabKind, contentMode: contentMode, isConnected: isConnected)
                    ) {
                        #expect(Self.menuBarTitles.contains(title), "\(title) has no menu-bar twin")
                    }
                }
            }
        }
    }

    /// The list above is only a claim until the menu bar is asked. Every title in it has to be one the
    /// built menu bar draws, a submenu's own row included, or a pull-down entry could name a twin
    /// that does not exist and the rule would pass on a typo.
    @Test("Every twin the rule names is in the built menu bar")
    @MainActor
    func menuBarTitlesAreInTheMenuBar() {
        var drawn: Set<String> = []
        collectTitles(from: MainMenuBuilder.build(keyboard: KeyboardSettings()), into: &drawn)

        #expect(drawn.count > 50, "Only \(drawn.count) titles collected; the walk missed the menus")
        for title in Self.menuBarTitles {
            #expect(drawn.contains(title), "\(title) is named as a twin but the menu bar has no such item")
        }
    }

    @MainActor
    private func collectTitles(from menu: NSMenu, into titles: inout Set<String>) {
        for item in menu.items where !item.isSeparatorItem {
            titles.insert(item.title)
            if let submenu = item.submenu { collectTitles(from: submenu, into: &titles) }
        }
    }

    /// A section is a run drawn between two separators. Past about six entries a run stops reading
    /// as a group and becomes a list, which is what the pull-down exists to avoid.
    @Test("No section runs longer than six entries")
    func sectionsStayShort() {
        for tabKind in Self.tabKinds + [nil] {
            for contentMode in ConnectionWorkspaceContentMode.allCases {
                for isConnected in [true, false] {
                    let sections = ConnectionActionsMenuResolver.sections(
                        Self.context(tabKind: tabKind, contentMode: contentMode, isConnected: isConnected)
                    )
                    for section in sections {
                        #expect(section.entries.count <= 6)
                        #expect(section.entries.isEmpty == false)
                    }
                }
            }
        }
    }

    @Test("A command never appears twice in one menu")
    func titlesAreUniqueWithinAMenu() {
        for tabKind in Self.tabKinds + [nil] {
            for contentMode in ConnectionWorkspaceContentMode.allCases {
                let titles = Self.titles(Self.context(tabKind: tabKind, contentMode: contentMode))
                #expect(Set(titles).count == titles.count)
            }
        }
    }

    /// The window always has a way out of itself, whatever it is showing and whether or not the
    /// connection is up. This is what lets the pull-down stay enabled in every phase.
    @Test("Every context offers a route to another connection")
    func everyContextOffersSwitchConnection() {
        for tabKind in Self.tabKinds + [nil] {
            for contentMode in ConnectionWorkspaceContentMode.allCases {
                for isConnected in [true, false] {
                    let titles = Self.titles(
                        Self.context(tabKind: tabKind, contentMode: contentMode, isConnected: isConnected)
                    )
                    #expect(titles.contains(String(localized: "Switch Connection…")))
                    #expect(titles.contains(String(localized: "Close Connection")))
                }
            }
        }
    }

    // MARK: - Capability gates

    @Test("Import is offered only by an engine that has it")
    func importFollowsTheDriver() {
        let withImport = Self.entries(Self.context(supportsImport: true))
        let without = Self.entries(Self.context(supportsImport: false))

        #expect(withImport.contains { $0.submenu == .importFormats })
        #expect(withImport.contains { $0.selector == NSSelectorFromString("importData:") })
        #expect(without.contains { $0.submenu == .importFormats } == false)
        #expect(without.contains { $0.selector == NSSelectorFromString("importData:") } == false)
    }

    /// The command ⇧⌘I runs is a leaf that says so, and the format list is a row of its own. A row
    /// that owns a submenu can carry neither an action nor a chord, so folding the two into one row
    /// drew a submenu with no command and no shortcut, and File > Import draws the same two rows.
    @Test("Import Data… is a plain leaf beside a list of formats, the way File > Import draws them")
    func importIsALeafBesideTheFormatList() throws {
        let entries = Self.entries(Self.context(supportsImport: true))
        let leaf = try #require(entries.first { $0.title == String(localized: "Import Data…") })
        let list = try #require(entries.first { $0.submenu == .importFormats })

        #expect(leaf.selector == NSSelectorFromString("importData:"))
        #expect(leaf.shortcut == .importData)
        #expect(leaf.submenu == nil)
        #expect(list.title == String(localized: "Import Data From"))
        #expect(list.title.hasSuffix("…") == false, "A submenu's row opens a menu, not a dialog, so it takes no ellipsis")
        let leafIndex = try #require(entries.firstIndex(of: leaf))
        #expect(entries.indices.contains(leafIndex + 1))
        #expect(entries[leafIndex + 1] == list, "The format list sits right under the command it refines")
    }

    /// A submenu's row is wired by AppKit to its submenu the moment one is assigned, and AppKit
    /// ignores a key equivalent on it, so a selector or a chord declared there is a promise the menu
    /// never keeps.
    @Test("No submenu row declares a selector or a shortcut")
    func submenuRowsDeclareNoCommand() {
        for tabKind in Self.tabKinds + [nil] {
            for contentMode in ConnectionWorkspaceContentMode.allCases {
                for isConnected in [true, false] {
                    let context = Self.context(tabKind: tabKind, contentMode: contentMode, isConnected: isConnected)
                    for entry in Self.entries(context) where entry.submenu != nil {
                        #expect(entry.selector == nil, "\(entry.title)")
                        #expect(entry.shortcut == nil, "\(entry.title)")
                    }
                }
            }
        }
    }

    @Test("Server Dashboard is offered only by an engine that has one")
    func dashboardFollowsTheDriver() {
        #expect(
            Self.titles(Self.context(supportsServerDashboard: true))
                .contains(String(localized: "Server Dashboard"))
        )
        #expect(
            Self.titles(Self.context(supportsServerDashboard: false))
                .contains(String(localized: "Server Dashboard")) == false
        )
    }

    /// Agent mode is the AI feature, so with the setting off there is no mode to choose between.
    @Test("The Mode submenu is offered only while AI is on")
    func modeSubmenuFollowsTheSetting() {
        #expect(Self.entries(Self.context(isAIEnabled: true)).contains { $0.submenu == .mode })
        #expect(Self.entries(Self.context(isAIEnabled: false)).contains { $0.submenu == .mode } == false)
    }

    @Test("Reconnect is offered only when there is nothing connected")
    func reconnectFollowsTheSession() {
        #expect(
            Self.titles(Self.context(isConnected: false)).contains(String(localized: "Reconnect"))
        )
        #expect(
            Self.titles(Self.context(isConnected: true)).contains(String(localized: "Reconnect")) == false
        )
    }

    // MARK: - Per-context content

    /// Add Row asks the same question the grid does, so it follows the results mode rather than the
    /// tab kind alone.
    @Test("Add Row is offered on a table tab showing data and nowhere else", arguments: ResultsViewMode.allCases)
    func addRowFollowsTheResultsMode(mode: ResultsViewMode) {
        let onTable = Self.titles(Self.context(tabKind: .table, resultsMode: mode))
        #expect(onTable.contains(String(localized: "Add Row")) == (mode == .data))
    }

    @Test("Add Row is never offered outside a table tab", arguments: tabKinds.filter { $0 != .table })
    func addRowIsTableOnly(tabKind: TabType) {
        #expect(
            Self.titles(Self.context(tabKind: tabKind)).contains(String(localized: "Add Row")) == false
        )
    }

    @Test("Show Results is offered on a query tab and nowhere else", arguments: tabKinds)
    func showResultsIsQueryOnly(tabKind: TabType) {
        let offered = Self.titles(Self.context(tabKind: tabKind)).contains(String(localized: "Show Results"))
        #expect(offered == (tabKind == .query))
    }

    /// Back and Forward walk a table's own browse history, which only a table tab has. They were
    /// two permanent hit targets in the titlebar and dim on the other seven kinds.
    @Test("Back and Forward are offered on a table tab and nowhere else", arguments: tabKinds)
    func navigationIsTableOnly(tabKind: TabType) {
        let titles = Self.titles(Self.context(tabKind: tabKind))
        #expect(titles.contains(String(localized: "Back")) == (tabKind == .table))
        #expect(titles.contains(String(localized: "Forward")) == (tabKind == .table))
    }

    @Test("An unsaved definition offers its preview but nothing that reads rows")
    func createTableOffersPreviewOnly() {
        let titles = Self.titles(Self.context(tabKind: .createTable))
        #expect(titles.contains(String(localized: "Preview SQL")))
        #expect(titles.contains(String(localized: "Add Row")) == false)
        #expect(titles.contains(String(localized: "Export Results…")) == false)
    }

    /// Agent mode has no grid, no object browser and no tab to act on, so the pull-down carries the
    /// window's own commands and stops.
    @Test("Agent mode offers only the mode and the connection")
    func agentModeIsMinimal() {
        let titles = Self.titles(Self.context(contentMode: .agent))
        #expect(titles.contains(String(localized: "Mode")))
        #expect(titles.contains(String(localized: "Switch Connection…")))
        #expect(titles.contains(String(localized: "Close Connection")))
        #expect(titles.contains(String(localized: "Add Row")) == false)
        #expect(titles.contains(String(localized: "Show Query History")) == false)
        #expect(titles.contains(String(localized: "New Tab")) == false)
    }

    /// A window whose connection went away offers the three commands that can do something about
    /// it, and nothing that needs a session.
    @Test("A window with no session offers only what can be done without one")
    func disconnectedIsMinimal() {
        let titles = Self.titles(Self.context(isConnected: false))
        #expect(titles.contains(String(localized: "Switch Connection…")))
        #expect(titles.contains(String(localized: "Reconnect")))
        #expect(titles.contains(String(localized: "Close Connection")))
        #expect(titles.contains(String(localized: "Export Tables…")) == false)
        #expect(titles.contains(String(localized: "Show Query History")) == false)
    }

    // MARK: - Selectors

    /// Every selector is spelled exactly as the class declares it. A selector with a colon the
    /// implementation does not have reaches nothing and AppKit draws the entry disabled, which
    /// fails quietly.
    @Test("Reconnect takes no sender, as the menu bar spells it")
    func reconnectTakesNoSender() {
        let reconnect = Self.entries(Self.context(isConnected: false))
            .first { $0.title == String(localized: "Reconnect") }
        #expect(reconnect?.selector == NSSelectorFromString("retryConnection"))
    }

    @Test("Every entry is a titled command with a selector, or a titled submenu row")
    func everyEntryIsComplete() {
        for tabKind in Self.tabKinds + [nil] {
            for contentMode in ConnectionWorkspaceContentMode.allCases {
                for entry in Self.entries(Self.context(tabKind: tabKind, contentMode: contentMode)) {
                    #expect(entry.title.isEmpty == false)
                    #expect((entry.selector == nil) == (entry.submenu != nil), "\(entry.title)")
                    if let selector = entry.selector {
                        #expect(NSStringFromSelector(selector).isEmpty == false)
                    }
                }
            }
        }
    }
}
