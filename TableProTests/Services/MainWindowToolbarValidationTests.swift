//
//  MainWindowToolbarValidationTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class RecordingToolbar: NSToolbar {
    typealias PendingSnapshot = (hasPendingChanges: Bool, hasDataPendingChanges: Bool)

    private(set) var validationCount = 0
    private(set) var pendingSnapshots: [PendingSnapshot] = []
    var pendingSnapshotProvider: (() -> PendingSnapshot)?

    override func validateVisibleItems() {
        validationCount += 1
        if let snapshot = pendingSnapshotProvider?() {
            pendingSnapshots.append(snapshot)
        }
    }
}

/// Every toolbar item answers from `ToolbarContextResolver`, so the rules are pinned against a
/// `ToolbarContext` value, and the cases that need a live toolbar build one.
@MainActor
struct MainWindowToolbarValidationTests {
    private let sessionScopedIdentifiers: [NSToolbarItem.Identifier] = [
        MainWindowToolbar.refresh,
        MainWindowToolbar.quickSwitcher,
        MainWindowToolbar.newTab,
        MainWindowToolbar.exportTables,
        MainWindowToolbar.saveChanges,
        MainWindowToolbar.previewSQL,
        MainWindowToolbar.database,
        MainWindowToolbar.dashboard,
        MainWindowToolbar.importTables,
        MainWindowToolbar.results,
        MainWindowToolbar.safeMode,
        MainWindowToolbar.history,
    ]

    private func makeContext(
        connected: Bool = true,
        tabKind: TabType? = .query,
        pendingChange: PendingChangeKind? = nil,
        hasDataPendingChanges: Bool = false,
        blocksAllWrites: Bool = false,
        fileBased: Bool = false,
        supportsContainerSwitching: Bool = true,
        supportsImport: Bool = true,
        supportsServerDashboard: Bool = true
    ) -> ToolbarContext {
        ToolbarContext(
            tabKind: tabKind,
            pane: connected ? .content : .unavailable(.notConnected),
            isConnected: connected,
            hasSelectedWorkspace: true,
            pendingChange: pendingChange,
            hasDataPendingChanges: hasDataPendingChanges,
            blocksAllWrites: blocksAllWrites,
            isFileBased: fileBased,
            supportsContainerSwitching: supportsContainerSwitching,
            supportsImport: supportsImport,
            supportsServerDashboard: supportsServerDashboard
        )
    }

    private func isEnabled(_ identifier: NSToolbarItem.Identifier, _ context: ToolbarContext) -> Bool {
        ToolbarContextResolver.isEnabled(identifier, context: context)
    }

    private func makeRecordingOwner() -> (owner: MainWindowToolbar, toolbar: RecordingToolbar) {
        let identifier = NSToolbar.Identifier("com.TablePro.tests.toolbar.\(UUID().uuidString)")
        let toolbar = RecordingToolbar(identifier: identifier)
        let owner = MainWindowToolbar(managedToolbar: toolbar)
        toolbar.autosavesConfiguration = false
        return (owner, toolbar)
    }

    private func waitForValidation(_ toolbar: RecordingToolbar, after baseline: Int) async {
        for _ in 0..<10 {
            guard toolbar.validationCount <= baseline else { return }
            await Task.yield()
        }
    }

    private func drainMainActor() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }

    @Test("Save Changes disabled when safe mode blocks writes")
    func saveChangesBlockedBySafeMode() {
        let context = makeContext(pendingChange: .data, blocksAllWrites: true)
        #expect(isEnabled(MainWindowToolbar.saveChanges, context) == false)
    }

    @Test("Save Changes disabled when no pending changes")
    func saveChangesDisabledWhenNoPending() {
        #expect(isEnabled(MainWindowToolbar.saveChanges, makeContext()) == false)
    }

    @Test("Save Changes enabled when pending changes, connected, writes allowed")
    func saveChangesEnabledHappyPath() {
        #expect(isEnabled(MainWindowToolbar.saveChanges, makeContext(pendingChange: .data)))
    }

    /// The defect `PendingChangeKind` was introduced for: staged principals are a pending change,
    /// and the commit control has to answer for them like any other kind.
    @Test("Save Changes answers for every kind of staged change", arguments: [
        PendingChangeKind.data, .structure, .createTable, .principals, .file,
    ])
    func saveChangesAnswersForEveryKind(kind: PendingChangeKind) {
        #expect(isEnabled(MainWindowToolbar.saveChanges, makeContext(pendingChange: kind)))
    }

    @Test("Save Changes disabled when disconnected")
    func saveChangesDisabledWhenDisconnected() {
        let context = makeContext(connected: false, pendingChange: .data)
        #expect(isEnabled(MainWindowToolbar.saveChanges, context) == false)
    }

    /// The results pane belongs to the query editor. The shipped rule was `!isTableTab`, which
    /// enabled it on the five kinds that have no results pane at all.
    @Test("Results answers on a query tab and nowhere else", arguments: [
        TabType.query, .table, .createTable, .erDiagram, .serverDashboard, .usersRoles, .insights, .objectSource,
    ])
    func resultsIsPerTabKind(tabKind: TabType) {
        #expect(isEnabled(MainWindowToolbar.results, makeContext(tabKind: tabKind)) == (tabKind == .query))
    }

    @Test("Database switcher disabled for file-based connections")
    func databaseDisabledForFileBased() {
        #expect(isEnabled(MainWindowToolbar.database, makeContext(fileBased: true)) == false)
        #expect(isEnabled(MainWindowToolbar.database, makeContext(fileBased: false)))
    }

    @Test("Database switcher requires plugin support")
    func databaseRequiresPluginSupport() {
        #expect(isEnabled(MainWindowToolbar.database, makeContext(supportsContainerSwitching: false)) == false)
        #expect(isEnabled(MainWindowToolbar.database, makeContext(supportsContainerSwitching: true)))
    }

    @Test("Import disabled when safe mode blocks writes")
    func importBlockedBySafeMode() {
        #expect(isEnabled(MainWindowToolbar.importTables, makeContext(blocksAllWrites: true)) == false)
    }

    @Test("Import requires plugin support")
    func importRequiresPluginSupport() {
        #expect(isEnabled(MainWindowToolbar.importTables, makeContext(supportsImport: false)) == false)
    }

    @Test("Export requires only connection")
    func exportRequiresConnection() {
        #expect(isEnabled(MainWindowToolbar.exportTables, makeContext(connected: true)))
        #expect(isEnabled(MainWindowToolbar.exportTables, makeContext(connected: false)) == false)
    }

    @Test("Preview SQL requires data pending changes and connection")
    func previewSQLRequirements() {
        let neither = makeContext(connected: false, hasDataPendingChanges: false)
        let onlyConnected = makeContext(connected: true, hasDataPendingChanges: false)
        let onlyPending = makeContext(connected: false, hasDataPendingChanges: true)
        let both = makeContext(connected: true, hasDataPendingChanges: true)
        #expect(isEnabled(MainWindowToolbar.previewSQL, neither) == false)
        #expect(isEnabled(MainWindowToolbar.previewSQL, onlyConnected) == false)
        #expect(isEnabled(MainWindowToolbar.previewSQL, onlyPending) == false)
        #expect(isEnabled(MainWindowToolbar.previewSQL, both))
    }

    /// A dirty query file raises the commit control and has no grid SQL to preview. The two are
    /// computed from different inputs, and this is the case that tells them apart.
    @Test("A dirty query file lights Save and leaves Preview SQL dim")
    func dirtyFileIsNotPreviewable() {
        let context = makeContext(pendingChange: .file, hasDataPendingChanges: false)
        #expect(isEnabled(MainWindowToolbar.saveChanges, context))
        #expect(isEnabled(MainWindowToolbar.previewSQL, context) == false)
    }

    @Test("Dashboard requires plugin support and connection")
    func dashboardRequirements() {
        #expect(isEnabled(MainWindowToolbar.dashboard, makeContext(supportsServerDashboard: false)) == false)
        #expect(isEnabled(MainWindowToolbar.dashboard, makeContext(connected: false)) == false)
        #expect(isEnabled(MainWindowToolbar.dashboard, makeContext()))
    }

    /// Switch Connection is the window's command and the route back from a connection that failed,
    /// so it answers with no session. Query History used to share that arm and was live and inert
    /// over a window that had never connected.
    @Test("Connection answers without a session, and History does not")
    func connectionIsTheOnlyItemThatNeedsNoSession() {
        let disconnected = makeContext(connected: false)
        #expect(isEnabled(MainWindowToolbar.connection, disconnected))
        #expect(isEnabled(MainWindowToolbar.history, disconnected) == false)
        #expect(isEnabled(MainWindowToolbar.history, makeContext()))
    }

    /// The drawer is not mounted in Agent mode, and toggling it there flipped a persisted flag that
    /// sprang it open on the way back to browsing.
    @Test("History is gated on browsing")
    func historyIsGatedOnBrowsing() {
        let agent = ToolbarContext(
            tabKind: .query,
            contentMode: .agent,
            pane: .content,
            isConnected: true,
            hasSelectedWorkspace: true
        )
        #expect(isEnabled(MainWindowToolbar.history, agent) == false)
    }

    /// A button a user dragged in from Customize Toolbar answers the way View > Show Assistant does,
    /// in every state the menu command distinguishes. The toolbar is handed the command's own answer,
    /// so this builds each toolbar context from it the way `currentContext()` does.
    @Test("The Assistant item answers exactly as its menu command does")
    func assistantFollowsItsMenuCommand() {
        for command in Self.assistantCommandContexts {
            let menuAnswer = TrailingPaneCommandResolver.canToggleAssistant(command)
            let toolbar = ToolbarContext(
                tabKind: .query,
                contentMode: command.contentMode,
                pane: command.hasContent ? .content : .unavailable(.notConnected),
                isConnected: command.hasContent,
                hasSelectedWorkspace: true,
                canToggleAssistant: menuAnswer,
                isAIEnabled: command.isAIEnabled
            )
            #expect(isEnabled(MainWindowToolbar.assistant, toolbar) == menuAnswer)
        }
    }

    /// Agent mode draws the conversation as the content column and the result in the pane, so there
    /// is no assistant surface for either the button or the menu to show or hide there.
    @Test("The Assistant item is dimmed in Agent mode")
    func assistantIsDimmedInAgentMode() {
        let command = TrailingPaneCommandResolver.Context(
            contentMode: .agent,
            storedSurface: .assistant,
            isPaneOpen: true,
            isAIEnabled: true,
            hasContent: true
        )
        let agent = ToolbarContext(
            tabKind: .query,
            contentMode: .agent,
            pane: .content,
            isConnected: true,
            hasSelectedWorkspace: true,
            canToggleAssistant: TrailingPaneCommandResolver.canToggleAssistant(command),
            isAIEnabled: true
        )
        #expect(isEnabled(MainWindowToolbar.assistant, agent) == false)
    }

    /// The inspector's button was fixed for this before: a connection that drops with the pane open
    /// must still be able to close it, and the menu's Hide Assistant already can. A session check
    /// dimmed the button beside a live menu item.
    @Test("An assistant left open over a dropped connection can still be closed from the toolbar")
    func assistantOpenOverADroppedConnectionCanClose() {
        let command = TrailingPaneCommandResolver.Context(
            contentMode: .browse,
            storedSurface: .assistant,
            isPaneOpen: true,
            isAIEnabled: true,
            hasContent: false
        )
        let dropped = ToolbarContext(
            tabKind: .query,
            contentMode: .browse,
            pane: .unavailable(.notConnected),
            isConnected: false,
            hasSelectedWorkspace: true,
            canToggleTrailingPane: true,
            canToggleAssistant: TrailingPaneCommandResolver.canToggleAssistant(command),
            isAIEnabled: true
        )
        #expect(TrailingPaneCommandResolver.assistantToggle(command) == .hide)
        #expect(isEnabled(MainWindowToolbar.assistant, dropped))
    }

    private static var assistantCommandContexts: [TrailingPaneCommandResolver.Context] {
        var contexts: [TrailingPaneCommandResolver.Context] = []
        for contentMode in ConnectionWorkspaceContentMode.allCases {
            for storedSurface in TrailingPaneSurface.allCases where storedSurface.isUserSelectable {
                for isPaneOpen in [true, false] {
                    for isAIEnabled in [true, false] {
                        for hasContent in [true, false] {
                            contexts.append(
                                TrailingPaneCommandResolver.Context(
                                    contentMode: contentMode,
                                    storedSurface: storedSurface,
                                    isPaneOpen: isPaneOpen,
                                    isAIEnabled: isAIEnabled,
                                    hasContent: hasContent
                                )
                            )
                        }
                    }
                }
            }
        }
        return contexts
    }

    /// The toolbar with nothing behind it at all: no window, no coordinator. Switch Connection still
    /// answers through the live validation path, because the connection that went away is exactly
    /// what a user reaches for it to leave.
    @Test("Switch Connection answers with nothing behind the toolbar")
    func connectionItemAnswersWithNoSubject() {
        let owner = MainWindowToolbar()
        #expect(owner.validateToolbarItem(NSToolbarItem(itemIdentifier: MainWindowToolbar.connection)))
        #expect(isEnabled(MainWindowToolbar.connection, ToolbarContext()))
    }

    /// Everything else here acts on the connection that is showing, so no subject still disables
    /// it rather than leaving a live-looking button that does nothing.
    @Test("Every other toolbar item still needs the connection it acts on")
    func otherItemsNeedASubject() {
        let owner = MainWindowToolbar()
        let connectionScoped = MainWindowToolbar.allowedItemIdentifiers.filter {
            $0 != MainWindowToolbar.connection && !$0.rawValue.hasPrefix("NSToolbar")
        }
        for identifier in connectionScoped + [MainWindowToolbar.navigateBack, MainWindowToolbar.navigateForward] {
            #expect(
                !owner.validateToolbarItem(NSToolbarItem(itemIdentifier: identifier)),
                "\(identifier.rawValue) answered with no connection behind it"
            )
        }
    }

    /// The old switch ended in `default: return true`, so every identifier nobody had thought about
    /// was live, including over a window with no coordinator and no session.
    @Test("An unknown identifier does not answer")
    func unknownIdentifierIsDisabled() {
        let unknown = NSToolbarItem.Identifier("com.test.unknown")
        #expect(isEnabled(unknown, makeContext()) == false)
        #expect(isEnabled(unknown, makeContext(connected: false)) == false)
    }

    /// On macOS 13 the delegate builds its own Inspector item targeting the toolbar, so this arm is
    /// what that button draws. It follows whether the pane can be toggled, which is AppKit's own
    /// rule on 14 and later: a connection that drops with the pane open can still close it, and a
    /// live session is not by itself a reason to open one.
    @Test("The inspector toggle answers whether the pane can be toggled, not whether a session is up")
    func inspectorFollowsTheTrailingPane() {
        let closable = ToolbarContext(
            pane: .unavailable(.notConnected),
            isConnected: false,
            hasSelectedWorkspace: true,
            canToggleTrailingPane: true
        )
        let stranded = ToolbarContext(
            pane: .content,
            isConnected: true,
            hasSelectedWorkspace: true,
            canToggleTrailingPane: false
        )
        #expect(isEnabled(MainWindowToolbar.inspector, closable))
        #expect(isEnabled(MainWindowToolbar.inspector, stranded) == false)
    }

    /// The health monitor writes `.connecting` on every reconnect attempt while the window keeps
    /// showing the session's tabs and rows, so a backoff must not gray the toolbar out.
    @Test("A session that is up or reconnecting counts as live")
    func connectedAndReconnectingCountAsLiveSession() {
        #expect(MainWindowToolbar.hasLiveSession(.connected) == true)
        #expect(MainWindowToolbar.hasLiveSession(.connecting) == true)
        #expect(MainWindowToolbar.hasLiveSession(.disconnected) == false)
        #expect(MainWindowToolbar.hasLiveSession(.error("boom")) == false)
    }

    /// The connection's state and whether a query is running are two axes. They shared one case
    /// until #2342, which is how a connection that was merely dialing painted the query indicator.
    @Test("A running query does not change what the connection state says")
    func runningQueryDoesNotChangeConnectionState() {
        let state = ConnectionToolbarState()
        state.updateConnectionState(from: .connected)
        #expect(state.connectionState == .connected)

        state.updateConnectionState(from: .connecting)
        #expect(state.connectionState == .connecting)

        state.updateConnectionState(from: .disconnected)
        #expect(MainWindowToolbar.hasLiveSession(state.connectionState) == false)
    }

    /// A failure's message is part of the state, so the same failure has to compare equal to itself.
    @Test("A connection error keeps its message through the mapping")
    func connectionErrorKeepsItsMessage() {
        #expect(ToolbarConnectionState(status: .error("boom")) == .error("boom"))
        #expect(ToolbarConnectionState(status: .connecting) == .connecting)
        #expect(ToolbarConnectionState(status: .connected) == .connected)
        #expect(ToolbarConnectionState(status: .disconnected) == .disconnected)
    }

    @Test("Session-scoped items stay enabled while a query runs")
    func sessionScopedItemsStayEnabledWhileExecuting() {
        let context = makeContext(
            connected: MainWindowToolbar.hasLiveSession(.connected),
            pendingChange: .data,
            hasDataPendingChanges: true
        )
        for identifier in sessionScopedIdentifiers {
            #expect(isEnabled(identifier, context), "\(identifier.rawValue)")
        }
    }

    @Test("Session-scoped items stay disabled when the session is gone")
    func sessionScopedItemsDisabledWhenNotLive() {
        for state: ToolbarConnectionState in [.disconnected, .error("boom")] {
            let context = makeContext(
                connected: MainWindowToolbar.hasLiveSession(state),
                pendingChange: .data,
                hasDataPendingChanges: true
            )
            for identifier in sessionScopedIdentifiers {
                #expect(isEnabled(identifier, context) == false, "\(identifier.rawValue)")
            }
        }
    }

    @Test("Item validation reads the live session, not the connected state alone")
    func validateToolbarItemFollowsLiveSession() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }
        let owner = MainWindowToolbar()
        owner.repoint(to: coordinator)
        let refresh = NSToolbarItem(itemIdentifier: MainWindowToolbar.refresh)

        coordinator.toolbarState.connectionState = .connected
        #expect(owner.validateToolbarItem(refresh) == true)

        _ = coordinator.tabExecution.claim(UUID())
        #expect(coordinator.toolbarState.connectionState == .connected)
        #expect(owner.validateToolbarItem(refresh) == true)

        coordinator.toolbarState.connectionState = .disconnected
        #expect(owner.validateToolbarItem(refresh) == false)
    }

    @Test("Pending changes revalidate native items with the final state")
    func pendingChangesRevalidateNativeItems() async throws {
        let coordinator = makeCoordinator()
        let (owner, toolbar) = makeRecordingOwner()
        defer {
            owner.invalidate()
            coordinator.teardown()
        }
        coordinator.toolbarState.connectionState = .connected
        toolbar.pendingSnapshotProvider = {
            (
                coordinator.toolbarState.hasPendingChanges,
                coordinator.toolbarState.hasDataPendingChanges
            )
        }
        owner.repoint(to: coordinator)

        let dirtyBaseline = toolbar.validationCount
        coordinator.toolbarState.hasDataPendingChanges = true
        coordinator.toolbarState.hasPendingChanges = true
        await waitForValidation(toolbar, after: dirtyBaseline)

        #expect(toolbar.validationCount > dirtyBaseline)
        let dirtySnapshot = try #require(toolbar.pendingSnapshots.last)
        #expect(dirtySnapshot.hasPendingChanges == true)
        #expect(dirtySnapshot.hasDataPendingChanges == true)

        let cleanBaseline = toolbar.validationCount
        coordinator.toolbarState.hasDataPendingChanges = false
        coordinator.toolbarState.hasPendingChanges = false
        await waitForValidation(toolbar, after: cleanBaseline)

        #expect(toolbar.validationCount > cleanBaseline)
        let cleanSnapshot = try #require(toolbar.pendingSnapshots.last)
        #expect(cleanSnapshot.hasPendingChanges == false)
        #expect(cleanSnapshot.hasDataPendingChanges == false)
    }

    /// The overflow menu validates as menu items, through `validateMenuItem`, so it has to reach the
    /// same resolver the buttons do. `pendingChange` is what `updateToolbarPendingState()` writes
    /// beside `hasPendingChanges`, and it is the one the commit control reads.
    @Test("Overflow Save and Preview use the pending-change predicates")
    func overflowPendingActionsValidateAgainstCurrentState() throws {
        let coordinator = makeCoordinator()
        let owner = MainWindowToolbar()
        defer {
            owner.invalidate()
            coordinator.teardown()
        }
        coordinator.toolbarState.connectionState = .connected
        owner.repoint(to: coordinator)

        let saveItem = try #require(
            owner.toolbar(
                owner.managedToolbar,
                itemForItemIdentifier: MainWindowToolbar.saveChanges,
                willBeInsertedIntoToolbar: true
            )
        )
        let saveMenuItem = try #require(saveItem.menuFormRepresentation)
        let previewItem = try #require(
            owner.toolbar(
                owner.managedToolbar,
                itemForItemIdentifier: MainWindowToolbar.previewSQL,
                willBeInsertedIntoToolbar: true
            )
        )
        let previewMenuItem = try #require(previewItem.menuFormRepresentation)

        coordinator.toolbarState.pendingChange = .data
        coordinator.toolbarState.hasDataPendingChanges = true
        #expect(owner.validateMenuItem(saveMenuItem) == true)
        #expect(owner.validateMenuItem(previewMenuItem) == true)

        coordinator.toolbarState.pendingChange = nil
        coordinator.toolbarState.hasDataPendingChanges = false
        #expect(owner.validateMenuItem(saveMenuItem) == false)
        #expect(owner.validateMenuItem(previewMenuItem) == false)
    }

    @Test("A queued validation cannot cross a toolbar repoint")
    func queuedValidationCannotCrossRepoint() async {
        let first = makeCoordinator()
        let second = makeCoordinator()
        let (owner, toolbar) = makeRecordingOwner()
        defer {
            owner.invalidate()
            first.teardown()
            second.teardown()
        }

        owner.repoint(to: first)
        first.toolbarState.hasPendingChanges = true
        owner.repoint(to: second)
        let repointBaseline = toolbar.validationCount
        await drainMainActor()
        #expect(toolbar.validationCount == repointBaseline)

        first.toolbarState.hasPendingChanges = false
        await drainMainActor()
        #expect(toolbar.validationCount == repointBaseline)

        second.toolbarState.hasPendingChanges = true
        await waitForValidation(toolbar, after: repointBaseline)
        #expect(toolbar.validationCount > repointBaseline)
    }

    @Test("Invalidation drops queued and future pending-state callbacks")
    func invalidationDropsPendingStateCallbacks() async {
        let coordinator = makeCoordinator()
        let (owner, toolbar) = makeRecordingOwner()
        defer { coordinator.teardown() }

        owner.repoint(to: coordinator)
        coordinator.toolbarState.hasPendingChanges = true
        owner.invalidate()
        let invalidationBaseline = toolbar.validationCount
        await drainMainActor()
        #expect(toolbar.validationCount == invalidationBaseline)

        coordinator.toolbarState.hasPendingChanges = false
        await drainMainActor()
        #expect(toolbar.validationCount == invalidationBaseline)
    }

    @Test("Toolbar is configured for user customization and autosave")
    func toolbarConfigurationEnablesAutosave() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }
        let owner = MainWindowToolbar()
        owner.repoint(to: coordinator)
        #expect(owner.managedToolbar.identifier == MainWindowToolbar.toolbarIdentifier)
        #expect(owner.managedToolbar.allowsUserCustomization == true)
        #expect(owner.managedToolbar.autosavesConfiguration == true)
    }

    @Test("Allowed item identifiers are a superset of defaults so restored items survive autosave")
    func allowedItemIdentifiersAreSupersetOfDefaults() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }
        let owner = MainWindowToolbar()
        owner.repoint(to: coordinator)
        let toolbar = owner.managedToolbar
        let defaults = Set(owner.toolbarDefaultItemIdentifiers(toolbar))
        let allowed = Set(owner.toolbarAllowedItemIdentifiers(toolbar))
        #expect(defaults.isSubset(of: allowed))
    }

    private func makeCoordinator() -> MainContentCoordinator {
        MainContentCoordinator(
            connection: TestFixtures.makeConnection(database: "db_a"),
            tabManager: QueryTabManager(),
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
    }
}

@MainActor
struct MainWindowToolbarRepointTests {
    private func makeCoordinator() -> MainContentCoordinator {
        MainContentCoordinator(
            connection: TestFixtures.makeConnection(database: "db_a"),
            tabManager: QueryTabManager(),
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
    }

    /// The window keeps one toolbar and points it at whichever connection it is showing, so a
    /// switch has to change what the items are about without rebuilding them.
    @Test("Repointing changes the subject the items read")
    func repointChangesTheSubject() {
        let first = makeCoordinator()
        let second = makeCoordinator()
        defer {
            first.teardown()
            second.teardown()
        }
        let owner = MainWindowToolbar()

        owner.repoint(to: first)
        #expect(owner.coordinator === first)

        owner.repoint(to: second)
        #expect(owner.coordinator === second)

        owner.repoint(to: nil)
        #expect(owner.coordinator == nil)
    }

    /// `windowDidBecomeKey` runs on every activation with the connection unchanged, so without the
    /// guard the window would re-observe, re-label and re-validate every item each time it came
    /// forward.
    @Test("Repointing to the same coordinator is a no-op")
    func repointToSameCoordinatorIsIgnored() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }
        let owner = MainWindowToolbar()

        owner.repoint(to: coordinator)
        owner.repoint(to: coordinator)
        #expect(owner.coordinator === coordinator)
    }

    /// The item is built once and outlives every connection the window shows, so anything it reads
    /// has to be resolved when it is asked, not when it was vended. Capturing the coordinator left
    /// the glyph reporting the results pane of the connection the user had switched away from, and
    /// pinned it to the collapsed glyph for good once that coordinator went away.
    @Test("The Results glyph follows the repointed connection")
    func resultsSymbolFollowsTheRepointedConnection() throws {
        let collapsed = makeCoordinator()
        let expanded = makeCoordinator()
        defer {
            collapsed.teardown()
            expanded.teardown()
        }
        collapsed.toolbarState.isResultsCollapsed = true
        expanded.toolbarState.isResultsCollapsed = false

        let owner = MainWindowToolbar()
        owner.repoint(to: collapsed)
        let item = try #require(
            owner.toolbar(
                owner.managedToolbar,
                itemForItemIdentifier: MainWindowToolbar.results,
                willBeInsertedIntoToolbar: true
            ) as? StatefulToolbarItem
        )
        let provider = try #require(item.symbolProvider)
        #expect(provider() == "rectangle.bottomhalf.inset.filled")

        owner.repoint(to: expanded)
        #expect(provider() == "rectangle.inset.filled")

        owner.repoint(to: nil)
        #expect(provider() == "rectangle.bottomhalf.inset.filled")
    }

    /// The delegate used to answer nil for every identifier when it had no coordinator. Measured on
    /// macOS 27 across separate launches, AppKit prunes an identifier from the saved arrangement as
    /// soon as the delegate stops vending it, so a vend that answered nil in that state removed the
    /// user's placed items for good.
    @Test("The delegate builds every advertised item with no subject")
    func delegateNeverAnswersNil() {
        let owner = MainWindowToolbar()
        let buildable = MainWindowToolbar.allowedItemIdentifiers.filter { !$0.rawValue.hasPrefix("NSToolbar") }

        for identifier in buildable {
            let item = owner.toolbar(
                owner.managedToolbar,
                itemForItemIdentifier: identifier,
                willBeInsertedIntoToolbar: true
            )
            #expect(item != nil, "\(identifier.rawValue) must still build with no connection")
        }
    }
}

@Suite("MainWindowToolbar back and forward validation")
@MainActor
struct MainWindowToolbarNavigationValidationTests {
    private func context(
        connected: Bool = true,
        canNavigateBack: Bool = false,
        canNavigateForward: Bool = false
    ) -> ToolbarContext {
        ToolbarContext(
            tabKind: .table,
            pane: connected ? .content : .unavailable(.notConnected),
            isConnected: connected,
            hasSelectedWorkspace: true,
            canNavigateBack: canNavigateBack,
            canNavigateForward: canNavigateForward,
            supportsContainerSwitching: true
        )
    }

    @Test("Back is disabled with an empty history rather than hidden")
    func backDisabledWithoutHistory() {
        #expect(ToolbarContextResolver.isEnabled(MainWindowToolbar.navigateBack, context: context()) == false)
    }

    @Test("Back is enabled once the tab has somewhere to go back to")
    func backEnabledWithHistory() {
        #expect(
            ToolbarContextResolver.isEnabled(
                MainWindowToolbar.navigateBack,
                context: context(canNavigateBack: true)
            )
        )
    }

    @Test("Back and Forward run out independently")
    func backAndForwardAreSeparate() {
        let onlyBack = context(canNavigateBack: true)
        #expect(ToolbarContextResolver.isEnabled(MainWindowToolbar.navigateBack, context: onlyBack))
        #expect(ToolbarContextResolver.isEnabled(MainWindowToolbar.navigateForward, context: onlyBack) == false)
    }

    @Test("Neither is offered without a connection")
    func bothNeedAConnection() {
        let disconnected = context(connected: false, canNavigateBack: true, canNavigateForward: true)
        #expect(ToolbarContextResolver.isEnabled(MainWindowToolbar.navigateBack, context: disconnected) == false)
        #expect(ToolbarContextResolver.isEnabled(MainWindowToolbar.navigateForward, context: disconnected) == false)
    }

    /// Two permanent hit targets for a command only a table tab has, so the pair left the default
    /// set. It is still offered by Customize Toolbar, and a user who puts it back gets a control
    /// that is always present and dims, since only the default set is ever hidden.
    @Test("The group is offered by the palette, not the default set")
    func groupIsPaletteOnly() {
        #expect(!MainWindowToolbar.defaultItemIdentifiers.contains(MainWindowToolbar.backForwardGroup))
        #expect(MainWindowToolbar.allowedItemIdentifiers.contains(MainWindowToolbar.backForwardGroup))
        #expect(!ToolbarContextResolver.hideableIdentifiers.contains(MainWindowToolbar.backForwardGroup))
    }
}

@Suite("MainWindowToolbar Add Row validation")
@MainActor
struct MainWindowToolbarAddRowValidationTests {
    private func context(
        connected: Bool, canAddRow: Bool, canRestorePreviousValues: Bool = false
    ) -> ToolbarContext {
        ToolbarContext(
            tabKind: .table,
            resultsMode: .data,
            pane: connected ? .content : .unavailable(.notConnected),
            isConnected: connected,
            hasSelectedWorkspace: true,
            canAddRow: canAddRow,
            canRestorePreviousValues: canRestorePreviousValues
        )
    }

    @Test("Add Row needs a live session and a tab that can take a row")
    func addRowEnablement() {
        #expect(ToolbarContextResolver.isEnabled(
            MainWindowToolbar.addRow,
            context: context(connected: true, canAddRow: true)
        ))
        #expect(!ToolbarContextResolver.isEnabled(
            MainWindowToolbar.addRow,
            context: context(connected: true, canAddRow: false)
        ))
        #expect(!ToolbarContextResolver.isEnabled(
            MainWindowToolbar.addRow,
            context: context(connected: false, canAddRow: true)
        ))
    }

    /// Reachable without a licence on purpose: the gate is at the point of use, where it can say
    /// what the licence buys. A dimmed item explains nothing.
    @Test("Restore Previous Values follows the tab, not the licence")
    func restorePreviousValuesValidation() {
        #expect(ToolbarContextResolver.isEnabled(
            MainWindowToolbar.restorePreviousValues,
            context: context(connected: true, canAddRow: false, canRestorePreviousValues: true)
        ))
        #expect(!ToolbarContextResolver.isEnabled(
            MainWindowToolbar.restorePreviousValues,
            context: context(connected: true, canAddRow: true, canRestorePreviousValues: false)
        ))
        #expect(!ToolbarContextResolver.isEnabled(
            MainWindowToolbar.restorePreviousValues,
            context: context(connected: false, canAddRow: true, canRestorePreviousValues: true)
        ))
    }
}
