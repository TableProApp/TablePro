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

@MainActor
struct MainWindowToolbarValidationTests {
    private let sessionScopedIdentifiers: [NSToolbarItem.Identifier] = [
        MainWindowToolbar.refresh,
        MainWindowToolbar.quickSwitcher,
        MainWindowToolbar.newTab,
        MainWindowToolbar.exportTables,
        MainWindowToolbar.sidebarToggle,
        MainWindowToolbar.saveChanges,
        MainWindowToolbar.previewSQL,
        MainWindowToolbar.database,
        MainWindowToolbar.dashboard,
        MainWindowToolbar.importTables,
        MainWindowToolbar.results
    ]

    private func makeContext(
        connected: Bool = true,
        isTableTab: Bool = false,
        canAddRow: Bool = false,
        canRestorePreviousValues: Bool = false,
        hasPendingChanges: Bool = false,
        hasDataPendingChanges: Bool = false,
        blocksAllWrites: Bool = false,
        fileBased: Bool = false,
        supportsContainerSwitching: Bool = true,
        supportsImport: Bool = true,
        supportsServerDashboard: Bool = true,
        canNavigateBack: Bool = false,
        canNavigateForward: Bool = false
    ) -> MainWindowToolbar.ValidationContext {
        MainWindowToolbar.ValidationContext(
            connected: connected,
            isTableTab: isTableTab,
            canAddRow: canAddRow,
            canRestorePreviousValues: canRestorePreviousValues,
            hasPendingChanges: hasPendingChanges,
            hasDataPendingChanges: hasDataPendingChanges,
            blocksAllWrites: blocksAllWrites,
            fileBased: fileBased,
            supportsContainerSwitching: supportsContainerSwitching,
            supportsImport: supportsImport,
            supportsServerDashboard: supportsServerDashboard,
            canNavigateBack: canNavigateBack,
            canNavigateForward: canNavigateForward
        )
    }

    private func makeRecordingOwner() -> (owner: MainWindowToolbar, toolbar: RecordingToolbar) {
        let identifier = NSToolbar.Identifier("com.TablePro.tests.toolbar.\(UUID().uuidString)")
        let toolbar = RecordingToolbar(identifier: identifier)
        return (MainWindowToolbar(managedToolbar: toolbar), toolbar)
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
        let context = makeContext(
            connected: true,
            hasPendingChanges: true,
            blocksAllWrites: true
        )
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.saveChanges, context: context) == false)
    }

    @Test("Save Changes disabled when no pending changes")
    func saveChangesDisabledWhenNoPending() {
        let context = makeContext(connected: true, hasPendingChanges: false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.saveChanges, context: context) == false)
    }

    @Test("Save Changes enabled when pending changes, connected, writes allowed")
    func saveChangesEnabledHappyPath() {
        let context = makeContext(connected: true, hasPendingChanges: true, blocksAllWrites: false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.saveChanges, context: context) == true)
    }

    @Test("Save Changes disabled when disconnected")
    func saveChangesDisabledWhenDisconnected() {
        let context = makeContext(connected: false, hasPendingChanges: true)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.saveChanges, context: context) == false)
    }

    @Test("Results enabled only off table tabs")
    func resultsDisabledOnTableTab() {
        let onTable = makeContext(connected: true, isTableTab: true)
        let onQuery = makeContext(connected: true, isTableTab: false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.results, context: onTable) == false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.results, context: onQuery) == true)
    }

    @Test("Database switcher disabled for file-based connections")
    func databaseDisabledForFileBased() {
        let fileBased = makeContext(connected: true, fileBased: true)
        let networked = makeContext(connected: true, fileBased: false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.database, context: fileBased) == false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.database, context: networked) == true)
    }

    @Test("Database switcher requires plugin support")
    func databaseRequiresPluginSupport() {
        let unsupported = makeContext(connected: true, supportsContainerSwitching: false)
        let supported = makeContext(connected: true, supportsContainerSwitching: true)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.database, context: unsupported) == false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.database, context: supported) == true)
    }

    @Test("Import disabled when safe mode blocks writes")
    func importBlockedBySafeMode() {
        let context = makeContext(connected: true, blocksAllWrites: true, supportsImport: true)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.importTables, context: context) == false)
    }

    @Test("Import requires plugin support")
    func importRequiresPluginSupport() {
        let context = makeContext(connected: true, supportsImport: false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.importTables, context: context) == false)
    }

    @Test("Export requires only connection")
    func exportRequiresConnection() {
        let connected = makeContext(connected: true)
        let disconnected = makeContext(connected: false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.exportTables, context: connected) == true)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.exportTables, context: disconnected) == false)
    }

    @Test("Preview SQL requires data pending changes and connection")
    func previewSQLRequirements() {
        let neither = makeContext(connected: false, hasDataPendingChanges: false)
        let onlyConnected = makeContext(connected: true, hasDataPendingChanges: false)
        let onlyPending = makeContext(connected: false, hasDataPendingChanges: true)
        let both = makeContext(connected: true, hasDataPendingChanges: true)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.previewSQL, context: neither) == false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.previewSQL, context: onlyConnected) == false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.previewSQL, context: onlyPending) == false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.previewSQL, context: both) == true)
    }

    @Test("Dashboard requires plugin support and connection")
    func dashboardRequirements() {
        let unsupported = makeContext(connected: true, supportsServerDashboard: false)
        let disconnected = makeContext(connected: false, supportsServerDashboard: true)
        let happy = makeContext(connected: true, supportsServerDashboard: true)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.dashboard, context: unsupported) == false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.dashboard, context: disconnected) == false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.dashboard, context: happy) == true)
    }

    @Test("Connection and History stay enabled regardless of connection state")
    func alwaysEnabledItems() {
        let disconnected = makeContext(connected: false)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.connection, context: disconnected) == true)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.history, context: disconnected) == true)
    }

    @Test("Unknown identifier defaults to enabled")
    func unknownIdentifierEnabled() {
        let context = makeContext(connected: false)
        let unknown = NSToolbarItem.Identifier("com.test.unknown")
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: unknown, context: context) == true)
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
            hasPendingChanges: true,
            hasDataPendingChanges: true
        )
        for identifier in sessionScopedIdentifiers {
            #expect(MainWindowToolbar.isEnabled(itemIdentifier: identifier, context: context) == true)
        }
    }

    @Test("Session-scoped items stay disabled when the session is gone")
    func sessionScopedItemsDisabledWhenNotLive() {
        for state: ToolbarConnectionState in [.disconnected, .error("boom")] {
            let context = makeContext(
                connected: MainWindowToolbar.hasLiveSession(state),
                hasPendingChanges: true,
                hasDataPendingChanges: true
            )
            for identifier in sessionScopedIdentifiers {
                #expect(MainWindowToolbar.isEnabled(itemIdentifier: identifier, context: context) == false)
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

        let saveGroup = try #require(
            owner.toolbar(
                owner.managedToolbar,
                itemForItemIdentifier: MainWindowToolbar.refreshSaveGroup,
                willBeInsertedIntoToolbar: true
            ) as? NSToolbarItemGroup
        )
        let saveItem = try #require(
            saveGroup.subitems.first { $0.itemIdentifier == MainWindowToolbar.saveChanges }
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

        coordinator.toolbarState.hasPendingChanges = true
        coordinator.toolbarState.hasDataPendingChanges = true
        #expect(owner.validateMenuItem(saveMenuItem) == true)
        #expect(owner.validateMenuItem(previewMenuItem) == true)

        coordinator.toolbarState.hasPendingChanges = false
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

    @Test("Toolbar identifier is stable across instances so AppKit autosave can persist customizations")
    func toolbarIdentifierIsStable() {
        #expect(MainWindowToolbar.toolbarIdentifier == "com.TablePro.main.toolbar.v2")
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

    /// `windowDidBecomeKey` runs on every activation with the connection unchanged, and
    /// `@Observable` generates no equality check, so a repoint to the same coordinator would
    /// otherwise invalidate the hosted items every time the window came forward.
    @Test("Repointing to the same coordinator is a no-op")
    func repointToSameCoordinatorIsIgnored() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }
        let owner = MainWindowToolbar()

        owner.repoint(to: coordinator)
        let subjectBefore = owner.subject.coordinator
        owner.repoint(to: coordinator)
        #expect(owner.subject.coordinator === subjectBefore)
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

    /// The delegate used to answer nil for every identifier when it had no coordinator. With
    /// `autosavesConfiguration` on, a vend in that state pruned the user's saved arrangement for
    /// good, which this project has already paid for once.
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
    ) -> MainWindowToolbar.ValidationContext {
        MainWindowToolbar.ValidationContext(
            connected: connected,
            isTableTab: true,
            canAddRow: false,
            canRestorePreviousValues: false,
            hasPendingChanges: false,
            hasDataPendingChanges: false,
            blocksAllWrites: false,
            fileBased: false,
            supportsContainerSwitching: true,
            supportsImport: true,
            supportsServerDashboard: true,
            canNavigateBack: canNavigateBack,
            canNavigateForward: canNavigateForward
        )
    }

    @Test("Back is disabled with an empty history rather than hidden")
    func backDisabledWithoutHistory() {
        #expect(
            MainWindowToolbar.isEnabled(
                itemIdentifier: MainWindowToolbar.navigateBack,
                context: context()
            ) == false
        )
    }

    @Test("Back is enabled once the tab has somewhere to go back to")
    func backEnabledWithHistory() {
        #expect(
            MainWindowToolbar.isEnabled(
                itemIdentifier: MainWindowToolbar.navigateBack,
                context: context(canNavigateBack: true)
            )
        )
    }

    @Test("Back and Forward run out independently")
    func backAndForwardAreSeparate() {
        let onlyBack = context(canNavigateBack: true)
        #expect(MainWindowToolbar.isEnabled(itemIdentifier: MainWindowToolbar.navigateBack, context: onlyBack))
        #expect(
            MainWindowToolbar.isEnabled(
                itemIdentifier: MainWindowToolbar.navigateForward,
                context: onlyBack
            ) == false
        )
    }

    @Test("Neither is offered without a connection")
    func bothNeedAConnection() {
        let disconnected = context(connected: false, canNavigateBack: true, canNavigateForward: true)
        #expect(
            MainWindowToolbar.isEnabled(
                itemIdentifier: MainWindowToolbar.navigateBack,
                context: disconnected
            ) == false
        )
        #expect(
            MainWindowToolbar.isEnabled(
                itemIdentifier: MainWindowToolbar.navigateForward,
                context: disconnected
            ) == false
        )
    }

    @Test("The group is offered by default so it reaches an existing toolbar")
    func groupIsADefaultItem() {
        #expect(MainWindowToolbar.defaultItemIdentifiers.contains(MainWindowToolbar.backForwardGroup))
        #expect(MainWindowToolbar.allowedItemIdentifiers.contains(MainWindowToolbar.backForwardGroup))
    }
}

@Suite("MainWindowToolbar Add Row validation")
@MainActor
struct MainWindowToolbarAddRowValidationTests {
    private func context(
        connected: Bool, canAddRow: Bool, canRestorePreviousValues: Bool = false
    ) -> MainWindowToolbar.ValidationContext {
        MainWindowToolbar.ValidationContext(
            connected: connected,
            isTableTab: true,
            canAddRow: canAddRow,
            canRestorePreviousValues: canRestorePreviousValues,
            hasPendingChanges: false,
            hasDataPendingChanges: false,
            blocksAllWrites: false,
            fileBased: false,
            supportsContainerSwitching: true,
            supportsImport: true,
            supportsServerDashboard: true,
            canNavigateBack: false,
            canNavigateForward: false
        )
    }

    @Test("Add Row needs a live session and a tab that can take a row")
    func addRowEnablement() {
        #expect(MainWindowToolbar.isEnabled(
            itemIdentifier: MainWindowToolbar.addRow,
            context: context(connected: true, canAddRow: true)
        ))
        #expect(!MainWindowToolbar.isEnabled(
            itemIdentifier: MainWindowToolbar.addRow,
            context: context(connected: true, canAddRow: false)
        ))
        #expect(!MainWindowToolbar.isEnabled(
            itemIdentifier: MainWindowToolbar.addRow,
            context: context(connected: false, canAddRow: true)
        ))
    }

    /// Reachable without a licence on purpose: the gate is at the point of use, where it can say
    /// what the licence buys. A dimmed item explains nothing.
    @Test("Restore Previous Values follows the tab, not the licence")
    func restorePreviousValuesValidation() {
        #expect(MainWindowToolbar.isEnabled(
            itemIdentifier: MainWindowToolbar.restorePreviousValues,
            context: context(connected: true, canAddRow: false, canRestorePreviousValues: true)
        ))
        #expect(!MainWindowToolbar.isEnabled(
            itemIdentifier: MainWindowToolbar.restorePreviousValues,
            context: context(connected: true, canAddRow: true, canRestorePreviousValues: false)
        ))
        #expect(!MainWindowToolbar.isEnabled(
            itemIdentifier: MainWindowToolbar.restorePreviousValues,
            context: context(connected: false, canAddRow: true, canRestorePreviousValues: true)
        ))
    }
}
