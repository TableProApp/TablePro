//
//  ToolbarContextResolverTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

struct ToolbarContextResolverTests {
    /// `TabType` is not `CaseIterable`, so the list is written out. A ninth kind fails the
    /// exhaustive switch in the resolver before it can fail here.
    private static let tabKinds: [TabType] = [
        .query, .table, .createTable, .erDiagram, .serverDashboard, .usersRoles, .insights, .objectSource,
    ]

    private static let panes: [ConnectionWindowPane] = [
        .connecting, .unavailable(.notConnected), .content, .empty,
    ]

    /// The hit targets in the default set: one sidebar toggle, the centred pair, the three content
    /// commands, Safe Mode and the trailing-pane toggle. Spacers and tracking separators take no
    /// click and are not counted.
    private static let defaultHitTargets: [NSToolbarItem.Identifier] = [
        .toggleSidebar,
        MainWindowToolbar.connection,
        MainWindowToolbar.database,
        MainWindowToolbar.refresh,
        MainWindowToolbar.saveChanges,
        MainWindowToolbar.actions,
        MainWindowToolbar.safeMode,
        MainWindowToolbar.inspector,
    ]

    private static func context(
        tabKind: TabType? = .table,
        resultsMode: ResultsViewMode? = .data,
        contentMode: ConnectionWorkspaceContentMode = .browse,
        pane: ConnectionWindowPane = .content,
        isFileBased: Bool = false,
        supportsContainerSwitching: Bool = true,
        isAIEnabled: Bool = true
    ) -> ToolbarContext {
        ToolbarContext(
            tabKind: tabKind,
            resultsMode: resultsMode,
            contentMode: contentMode,
            pane: pane,
            isConnected: pane == .content,
            hasSelectedWorkspace: true,
            canToggleTrailingPane: pane == .content,
            isFileBased: isFileBased,
            supportsContainerSwitching: supportsContainerSwitching,
            isAIEnabled: isAIEnabled
        )
    }

    private static func hidden(_ context: ToolbarContext) -> Set<NSToolbarItem.Identifier> {
        ToolbarContextResolver.visibility(for: context.visibilityKey).hidden
    }

    /// Every context the window can reach, as far as the item set is concerned.
    private static var everyContext: [ToolbarContext] {
        var contexts: [ToolbarContext] = []
        for tabKind in tabKinds + [nil] {
            for contentMode in ConnectionWorkspaceContentMode.allCases {
                for pane in panes {
                    for isFileBased in [true, false] {
                        for supportsContainerSwitching in [true, false] {
                            contexts.append(
                                context(
                                    tabKind: tabKind,
                                    contentMode: contentMode,
                                    pane: pane,
                                    isFileBased: isFileBased,
                                    supportsContainerSwitching: supportsContainerSwitching
                                )
                            )
                        }
                    }
                }
            }
        }
        return contexts
    }

    private static func visibleCount(_ context: ToolbarContext) -> Int {
        let hiddenSet = Self.hidden(context)
        return defaultHitTargets.filter { !hiddenSet.contains($0) }.count
    }

    // MARK: - The ceiling

    /// The whole point of the revamp: no context may put more than eight things to click in the
    /// titlebar. The guard test this replaces counted identifiers rather than hit targets, which is
    /// how a two-segment control was added to a full titlebar and passed.
    @Test("No reachable context exceeds eight hit targets")
    func hitTargetCeiling() {
        for tabKind in Self.tabKinds + [nil] {
            for contentMode in ConnectionWorkspaceContentMode.allCases {
                for pane in Self.panes {
                    for isFileBased in [true, false] {
                        let context = Self.context(
                            tabKind: tabKind,
                            contentMode: contentMode,
                            pane: pane,
                            isFileBased: isFileBased
                        )
                        #expect(Self.visibleCount(context) <= 8)
                    }
                }
            }
        }
    }

    @Test("Agent mode shows six")
    func agentModeShowsSix() {
        #expect(Self.visibleCount(Self.context(contentMode: .agent)) == 6)
    }

    @Test("A file-based connection drops the container capsule")
    func fileBasedShowsSeven() {
        #expect(Self.visibleCount(Self.context(isFileBased: true)) == 7)
    }

    // MARK: - What may be hidden

    /// An item the user dragged in from the customization palette is opt-in, so it stays where they
    /// put it and dims. Only the default set may be taken off screen.
    @Test("The hidden set never reaches past the default set")
    func hiddenStaysInsideTheDefaultSet() {
        for context in Self.everyContext {
            #expect(Self.hidden(context).isSubset(of: ToolbarContextResolver.hideableIdentifiers))
        }
    }

    /// The other half of the same rule, stated against the list a user actually drags from. With
    /// the intersection inside the resolver this holds for any context a later change invents,
    /// not only for the three items the contexts name today.
    @Test("An item only the palette offers is never hidden")
    func paletteOnlyItemsAreNeverHidden() {
        let paletteOnly = Set(MainWindowToolbar.allowedItemIdentifiers)
            .subtracting(MainWindowToolbar.defaultItemIdentifiers)
        #expect(!paletteOnly.isEmpty)
        for context in Self.everyContext {
            #expect(Self.hidden(context).isDisjoint(with: paletteOnly))
        }
    }

    /// Spaces and tracking separators are in the hideable set, because it is the default list and
    /// filtering them out by prefix would take the two pane toggles with them. A context has no
    /// reason to name one, and hiding a tracking separator would unhook the titlebar from a pane.
    @Test("No context hides a space or a tracking separator")
    func spacesAreNeverHidden() {
        var spaces: Set<NSToolbarItem.Identifier> = [.flexibleSpace, .space, .sidebarTrackingSeparator]
        if #available(macOS 14.0, *) {
            spaces.insert(.inspectorTrackingSeparator)
        }
        for context in Self.everyContext {
            #expect(Self.hidden(context).isDisjoint(with: spaces))
        }
    }

    /// The window's own identity, the pull-down that carries everything displaced, the control that
    /// says whether a keystroke can reach a live table, and the two pane toggles. None of these has
    /// a context in which it means nothing, and the connection capsule is also what Switch
    /// Connection presents from.
    @Test("The permanent controls are never hidden")
    func permanentControlsAreNeverHidden() {
        let permanent: Set<NSToolbarItem.Identifier> = [
            .toggleSidebar,
            MainWindowToolbar.connection,
            MainWindowToolbar.actions,
            MainWindowToolbar.safeMode,
            MainWindowToolbar.inspector,
        ]
        for context in Self.everyContext {
            #expect(Self.hidden(context).isDisjoint(with: permanent))
        }
    }

    // MARK: - The anti-reflow rule

    /// `isHidden` is written only from the slow-moving subset, so the item set can change on a tab
    /// switch, a mode switch or a connection switch and on nothing else. A keystroke in a cell
    /// editor builds the key, compares it and moves nothing.
    @Test("Visibility ignores everything transient")
    func visibilityIgnoresTransientState() {
        let quiet = ToolbarContext(
            tabKind: .table,
            resultsMode: .data,
            contentMode: .browse,
            pane: .content,
            isConnected: true,
            hasSelectedWorkspace: true,
            canToggleTrailingPane: true,
            supportsContainerSwitching: true
        )
        let busy = ToolbarContext(
            tabKind: .table,
            resultsMode: .data,
            contentMode: .browse,
            pane: .connecting,
            isConnected: false,
            hasSelectedWorkspace: true,
            canToggleTrailingPane: false,
            pendingChange: .data,
            hasDataPendingChanges: true,
            blocksAllWrites: true,
            canAddRow: true,
            canRestorePreviousValues: true,
            canNavigateBack: true,
            canNavigateForward: true,
            supportsContainerSwitching: true
        )

        #expect(quiet.visibilityKey == busy.visibilityKey)
        #expect(Self.hidden(quiet) == Self.hidden(busy))
    }

    /// The whole context and the key the toolbar builds on its own have to carry the same eight
    /// facts, or a context built for enablement would disagree with the shape it is drawn over.
    @Test("A context built over a key carries that key back")
    func contextOverAKeyRoundTrips() {
        let key = ToolbarContext.VisibilityKey(
            tabKind: .createTable,
            resultsMode: .structure,
            contentMode: .agent,
            isFileBased: true,
            supportsContainerSwitching: false,
            supportsImport: true,
            supportsServerDashboard: true,
            isAIEnabled: true
        )
        let context = ToolbarContext(
            key: key,
            pane: .content,
            isConnected: true,
            hasSelectedWorkspace: true,
            canToggleTrailingPane: true,
            pendingChange: .createTable,
            hasDataPendingChanges: false,
            blocksAllWrites: false,
            canAddRow: false,
            canRestorePreviousValues: false,
            canNavigateBack: false,
            canNavigateForward: false
        )

        #expect(context.visibilityKey == key)
        #expect(context.pendingChange == .createTable)
    }

    // MARK: - The commit verb

    /// The verb comes from the tab kind, never from what is staged, so an edit that makes a
    /// definition valid or invalid cannot relabel the control and reflow a labelled titlebar.
    @Test("The commit verb follows the tab kind", arguments: tabKinds + [nil])
    func commitVerbFollowsTheTabKind(tabKind: TabType?) {
        let expected: String
        switch tabKind {
        case .createTable:
            expected = String(localized: "Create Table")
        case .usersRoles:
            expected = String(localized: "Apply Changes")
        default:
            expected = String(localized: "Save Changes")
        }
        #expect(ToolbarContextResolver.commitVerb(for: tabKind) == expected)
    }

    /// Three verbs for three different commits. Two kinds sharing one would have the control offer
    /// to save a definition that is about to be created.
    @Test("The three commit verbs are distinct")
    func commitVerbsAreDistinct() {
        let verbs = Set([TabType.table, .createTable, .usersRoles].map { ToolbarContextResolver.commitVerb(for: $0) })
        #expect(verbs.count == 3)
    }

    // MARK: - Per-kind sets

    @Test("An unsaved definition has nothing to reload")
    func createTableHidesRefresh() {
        let hidden = Self.hidden(Self.context(tabKind: .createTable))
        #expect(hidden.contains(MainWindowToolbar.refresh))
        #expect(hidden.contains(MainWindowToolbar.saveChanges) == false)
    }

    @Test(
        "The four kinds that can never stage a change lose the commit control",
        arguments: [TabType.erDiagram, .serverDashboard, .insights, .objectSource]
    )
    func readOnlyKindsHideSaveChanges(tabKind: TabType) {
        let hidden = Self.hidden(Self.context(tabKind: tabKind))
        #expect(hidden.contains(MainWindowToolbar.saveChanges))
        #expect(hidden.contains(MainWindowToolbar.refresh) == false)
    }

    @Test("The three kinds that can stage a change keep both content commands", arguments: [
        TabType.query, .table, .usersRoles,
    ])
    func editableKindsKeepBoth(tabKind: TabType) {
        let hidden = Self.hidden(Self.context(tabKind: tabKind))
        #expect(hidden.contains(MainWindowToolbar.saveChanges) == false)
        #expect(hidden.contains(MainWindowToolbar.refresh) == false)
    }

    @Test("Agent mode has no grid to reload and nothing mounted to commit")
    func agentModeHidesBothContentCommands() {
        let hidden = Self.hidden(Self.context(contentMode: .agent))
        #expect(hidden.contains(MainWindowToolbar.refresh))
        #expect(hidden.contains(MainWindowToolbar.saveChanges))
    }

    @Test("A window with no selected tab keeps the full set")
    func noSelectedTabKeepsEverything() {
        #expect(Self.hidden(Self.context(tabKind: nil)).isEmpty)
    }

    @Test("The results mode never moves an item", arguments: ResultsViewMode.allCases)
    func resultsModeNeverMovesAnything(mode: ResultsViewMode) {
        #expect(
            Self.hidden(Self.context(resultsMode: mode))
                == Self.hidden(Self.context(resultsMode: .data))
        )
    }

    @Test("The container capsule goes when the engine has nothing to switch to")
    func containerCapsuleVisibility() {
        #expect(
            Self.hidden(Self.context(isFileBased: false, supportsContainerSwitching: true))
                .contains(MainWindowToolbar.database) == false
        )
        #expect(
            Self.hidden(Self.context(isFileBased: true, supportsContainerSwitching: true))
                .contains(MainWindowToolbar.database)
        )
        #expect(
            Self.hidden(Self.context(isFileBased: false, supportsContainerSwitching: false))
                .contains(MainWindowToolbar.database)
        )
    }

    // MARK: - Enablement

    /// Switch Connection is the window's command and the route back from a connection that failed,
    /// so it answers in every phase including the one with no session at all.
    @Test("Only the connection chooser answers over an empty pane")
    func emptyPaneDisablesEverythingButTheConnection() {
        let context = Self.context(pane: .empty)
        for identifier in Self.defaultHitTargets where identifier != MainWindowToolbar.connection {
            guard identifier != .toggleSidebar else { continue }
            #expect(ToolbarContextResolver.isEnabled(identifier, context: context) == false)
        }
        #expect(ToolbarContextResolver.isEnabled(MainWindowToolbar.connection, context: context))
    }

    /// The pull-down offers Switch Connection, Reconnect and Close Connection here, so it is the
    /// route out of a window whose connection went away.
    @Test("The pull-down answers while connecting and while unavailable", arguments: [
        ConnectionWindowPane.connecting, .unavailable(.notConnected),
    ])
    func actionsAnswersWithoutASession(pane: ConnectionWindowPane) {
        #expect(ToolbarContextResolver.isEnabled(MainWindowToolbar.actions, context: Self.context(pane: pane)))
    }

    /// The shipped rule was `connected && !isTableTab`, which enabled the command on the five kinds
    /// that have no results pane at all and then wrote a collapse flag with no tab-kind guard.
    @Test("Show Results answers on a query tab and nowhere else", arguments: tabKinds)
    func showResultsIsQueryOnly(tabKind: TabType) {
        let enabled = ToolbarContextResolver.isEnabled(
            MainWindowToolbar.results,
            context: Self.context(tabKind: tabKind)
        )
        #expect(enabled == (tabKind == .query))
    }

    /// The drawer is not mounted in Agent mode, and toggling it there flipped a persisted flag that
    /// sprang it open on the way back to browsing.
    @Test("Query History answers while browsing a live session and nowhere else")
    func queryHistoryGating() {
        #expect(ToolbarContextResolver.isEnabled(MainWindowToolbar.history, context: Self.context()))
        #expect(
            ToolbarContextResolver.isEnabled(
                MainWindowToolbar.history,
                context: Self.context(contentMode: .agent)
            ) == false
        )
        #expect(
            ToolbarContextResolver.isEnabled(
                MainWindowToolbar.history,
                context: Self.context(pane: .connecting)
            ) == false
        )
    }

    /// A connection that drops with the pane open must still be able to close it, which is the
    /// state the old `connected` rule disabled on the app's minimum OS.
    @Test("The trailing-pane toggle follows whether the pane can be toggled")
    func trailingPaneToggleFollowsItsOwnRule() {
        var context = Self.context(pane: .unavailable(.notConnected))
        #expect(ToolbarContextResolver.isEnabled(MainWindowToolbar.inspector, context: context) == false)

        context = ToolbarContext(
            tabKind: .table,
            contentMode: .browse,
            pane: .unavailable(.notConnected),
            isConnected: false,
            hasSelectedWorkspace: true,
            canToggleTrailingPane: true
        )
        #expect(ToolbarContextResolver.isEnabled(MainWindowToolbar.inspector, context: context))
    }

    /// The old switch ended in `default: return true`, so every identifier nobody had thought about
    /// was live, including over a window with no coordinator and no session.
    @Test("An identifier the toolbar does not vend does not answer")
    func unknownIdentifiersDoNotAnswer() {
        #expect(
            ToolbarContextResolver.isEnabled(
                NSToolbarItem.Identifier("com.TablePro.toolbar.nothingAtAll"),
                context: Self.context()
            ) == false
        )
    }

    @Test("The commit control answers only over staged work a safe mode allows")
    func commitControlGating() {
        var context = Self.context()
        #expect(ToolbarContextResolver.isEnabled(MainWindowToolbar.saveChanges, context: context) == false)

        context = ToolbarContext(
            tabKind: .table,
            contentMode: .browse,
            pane: .content,
            isConnected: true,
            hasSelectedWorkspace: true,
            pendingChange: .data,
            supportsContainerSwitching: true
        )
        #expect(ToolbarContextResolver.isEnabled(MainWindowToolbar.saveChanges, context: context))

        context = ToolbarContext(
            tabKind: .table,
            contentMode: .browse,
            pane: .content,
            isConnected: true,
            hasSelectedWorkspace: true,
            pendingChange: .data,
            blocksAllWrites: true,
            supportsContainerSwitching: true
        )
        #expect(ToolbarContextResolver.isEnabled(MainWindowToolbar.saveChanges, context: context) == false)
    }
}
