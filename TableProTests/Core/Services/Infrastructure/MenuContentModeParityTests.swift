//
//  MenuContentModeParityTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

/// The menu bar and the titlebar answer for one command, so they have to answer the same.
///
/// The revamp moved most of these commands out of the titlebar, which makes the menu bar the place
/// they now live: a command the toolbar's resolver refuses in Agent mode and the menu validator
/// still lights is more wrongly enabled than it was before the move, not less. Refresh over a grid
/// that is not mounted, Save over a commit gate frozen at the moment the mode changed, Command Y
/// flipping a persisted flag for a drawer that is not there and that then springs open on the way
/// back to browsing.
///
/// The pair table is the contract, and `everyBrowseOnlyItemHasAMenuTwin` derives it back out of the
/// toolbar so the table cannot be the only thing that knows: an item made browse-only there without
/// an entry here fails rather than ships enabled on the menu bar.
@MainActor
struct MenuContentModeParityTests {
    /// One command, spelled for each surface.
    private struct CommandPair {
        let selector: Selector
        let identifier: NSToolbarItem.Identifier
        var name: String { NSStringFromSelector(selector) }
    }

    private static let pairs: [CommandPair] = [
        CommandPair(
            selector: #selector(MainSplitViewController.refreshDatabase(_:)),
            identifier: MainWindowToolbar.refresh
        ),
        CommandPair(
            selector: #selector(MainSplitViewController.saveDocument(_:)),
            identifier: MainWindowToolbar.saveChanges
        ),
        CommandPair(
            selector: #selector(MainSplitViewController.addRow(_:)),
            identifier: MainWindowToolbar.addRow
        ),
        CommandPair(
            selector: #selector(MainSplitViewController.restorePreviousValues(_:)),
            identifier: MainWindowToolbar.restorePreviousValues
        ),
        CommandPair(
            selector: #selector(MainSplitViewController.previewSQL(_:)),
            identifier: MainWindowToolbar.previewSQL
        ),
        CommandPair(
            selector: #selector(MainSplitViewController.toggleResults(_:)),
            identifier: MainWindowToolbar.results
        ),
        CommandPair(
            selector: #selector(MainSplitViewController.toggleQueryHistory(_:)),
            identifier: MainWindowToolbar.history
        ),
        CommandPair(
            selector: #selector(MainSplitViewController.newEditorTab(_:)),
            identifier: MainWindowToolbar.newTab
        ),
        CommandPair(
            selector: #selector(MainSplitViewController.openQuickSwitcher(_:)),
            identifier: MainWindowToolbar.quickSwitcher
        ),
        CommandPair(
            selector: #selector(MainSplitViewController.exportTables(_:)),
            identifier: MainWindowToolbar.exportTables
        ),
        CommandPair(
            selector: #selector(MainSplitViewController.importData(_:)),
            identifier: MainWindowToolbar.importTables
        ),
        CommandPair(
            selector: #selector(MainSplitViewController.showServerDashboard(_:)),
            identifier: MainWindowToolbar.dashboard
        ),
        CommandPair(
            selector: #selector(MainSplitViewController.navigateBack(_:)),
            identifier: MainWindowToolbar.navigateBack
        ),
        CommandPair(
            selector: #selector(MainSplitViewController.navigateForward(_:)),
            identifier: MainWindowToolbar.navigateForward
        ),
    ]

    /// Everything either surface could ask about is true, so the content mode is the only thing left
    /// that can answer no. A query tab, because it is the one kind with a results pane, and the one
    /// the two Show Results rules are written against.
    private static func toolbarContext(_ contentMode: ConnectionWorkspaceContentMode) -> ToolbarContext {
        ToolbarContext(
            tabKind: .query,
            resultsMode: .data,
            contentMode: contentMode,
            pane: .content,
            isConnected: true,
            hasSelectedWorkspace: true,
            canToggleTrailingPane: true,
            pendingChange: .data,
            hasDataPendingChanges: true,
            canAddRow: true,
            canRestorePreviousValues: true,
            canNavigateBack: true,
            canNavigateForward: true,
            supportsContainerSwitching: true,
            supportsImport: true,
            supportsServerDashboard: true,
            isAIEnabled: true
        )
    }

    /// The same facts in the menu bar's vocabulary. `supportsImport` is the driver's capability and
    /// `hasImportFormats` the list it produced, which is the one place the two surfaces read a
    /// different fact about the same command; both are true here so the rule underneath is what the
    /// comparison sees.
    private static func menuContext(_ contentMode: ConnectionWorkspaceContentMode) -> MenuValidationContext {
        var context = MenuValidationContext()
        context.hasSelectedWorkspace = true
        context.isConnected = true
        context.isAgentMode = contentMode == .agent
        context.isQueryTab = true
        context.hasPendingChanges = true
        context.hasDataPendingChanges = true
        context.isCurrentTabEditable = true
        context.isCurrentTabSchemaResolved = true
        context.canRestorePreviousValues = true
        context.canNavigateBack = true
        context.canNavigateForward = true
        context.hasImportFormats = true
        context.supportsServerDashboard = true
        context.hasAssistantConversation = true
        context.hasStoredConversations = true
        return context
    }

    private static func menuAnswer(_ pair: CommandPair, _ contentMode: ConnectionWorkspaceContentMode) -> Bool {
        MainSplitViewController.isEnabled(pair.selector, context: menuContext(contentMode))
    }

    private static func toolbarAnswer(_ pair: CommandPair, _ contentMode: ConnectionWorkspaceContentMode) -> Bool {
        ToolbarContextResolver.isEnabled(pair.identifier, context: toolbarContext(contentMode))
    }

    @Test("Both surfaces give one answer per command in both modes")
    func surfacesAgree() {
        for contentMode in ConnectionWorkspaceContentMode.allCases {
            for pair in Self.pairs {
                #expect(
                    Self.menuAnswer(pair, contentMode) == Self.toolbarAnswer(pair, contentMode),
                    "\(pair.name) and \(pair.identifier.rawValue) disagree in \(contentMode.rawValue)"
                )
            }
        }
    }

    /// Without this the suite would pass over a table of commands that are disabled everywhere.
    @Test("Every command in the table answers while browsing")
    func browsingEnablesEveryPair() {
        for pair in Self.pairs {
            #expect(Self.menuAnswer(pair, .browse), "\(pair.name) is dim on the menu bar while browsing")
            #expect(Self.toolbarAnswer(pair, .browse), "\(pair.identifier.rawValue) is dim in the titlebar")
        }
    }

    @Test("Agent mode dims every command in the table")
    func agentModeDisablesEveryPair() {
        for pair in Self.pairs {
            #expect(!Self.menuAnswer(pair, .agent), "\(pair.name) stayed lit on the menu bar in Agent mode")
            #expect(!Self.toolbarAnswer(pair, .agent), "\(pair.identifier.rawValue) stayed lit in Agent mode")
        }
    }

    /// The table read back out of the toolbar. Every item the resolver makes browse-only has to have
    /// a menu twin here, or the command keeps a live menu-bar route into content the window is not
    /// drawing. The trailing-pane and assistant toggles are not derived: they carry their own mode
    /// answer in `canToggleTrailingPane` and `canToggleAssistant`, which the window computes.
    @Test("Every browse-only toolbar item has a menu twin in the table")
    func everyBrowseOnlyItemHasAMenuTwin() {
        let candidates = Set(
            MainWindowToolbar.allowedItemIdentifiers
                + [MainWindowToolbar.navigateBack, MainWindowToolbar.navigateForward]
        )
        let browseOnly = candidates.filter { identifier in
            ToolbarContextResolver.isEnabled(identifier, context: Self.toolbarContext(.browse))
                && !ToolbarContextResolver.isEnabled(identifier, context: Self.toolbarContext(.agent))
        }
        let covered = Set(Self.pairs.map(\.identifier))

        #expect(!browseOnly.isEmpty, "Nothing is browse-only, so this guard would pass vacuously")
        #expect(
            browseOnly.subtracting(covered).isEmpty,
            "Browse-only in the titlebar with no menu twin: \(browseOnly.subtracting(covered).map(\.rawValue))"
        )
        #expect(
            covered.subtracting(browseOnly).isEmpty,
            "In the table and not browse-only: \(covered.subtracting(browseOnly).map(\.rawValue))"
        )
    }

    /// The other half of the rule, and the part that keeps it honest. A command that still acts in
    /// Agent mode must answer the same in both modes: the window, the session and the conversation
    /// are all still there, and dimming them would take away the route out of a mode the user is in.
    @Test("The commands Agent mode still runs are untouched by it")
    func agentModeLeavesItsOwnCommandsAlone() {
        let unaffected: [Selector] = [
            #selector(MainSplitViewController.switchConnection(_:)),
            #selector(MainSplitViewController.closeConnection(_:)),
            #selector(MainSplitViewController.setSafeModeLevel(_:)),
            #selector(MainSplitViewController.setContentModeFromMenu(_:)),
            #selector(MainSplitViewController.toggleContentModeFromMenu(_:)),
            #selector(MainSplitViewController.newAIConversation(_:)),
            #selector(MainSplitViewController.switchAIConversation(_:)),
            #selector(MainSplitViewController.clearAIConversations(_:)),
            #selector(MainSplitViewController.focusAssistant(_:)),
            #selector(MainSplitViewController.toggleWorkspaceRail(_:)),
        ]

        for selector in unaffected {
            #expect(
                MainSplitViewController.isEnabled(selector, context: Self.menuContext(.agent))
                    == MainSplitViewController.isEnabled(selector, context: Self.menuContext(.browse)),
                "\(NSStringFromSelector(selector)) changed answer with the content mode"
            )
        }
    }

    /// Named rather than left to the equality above, which two disabled answers would also satisfy.
    @Test("The window's own commands still answer in Agent mode")
    func theWindowsCommandsAnswerInAgentMode() {
        let context = Self.menuContext(.agent)
        let live: [Selector] = [
            #selector(MainSplitViewController.switchConnection(_:)),
            #selector(MainSplitViewController.closeConnection(_:)),
            #selector(MainSplitViewController.setSafeModeLevel(_:)),
            #selector(MainSplitViewController.newAIConversation(_:)),
            #selector(MainSplitViewController.clearAIConversations(_:)),
        ]
        for selector in live {
            #expect(
                MainSplitViewController.isEnabled(selector, context: context),
                "\(NSStringFromSelector(selector)) is dim in Agent mode"
            )
        }
    }
}
