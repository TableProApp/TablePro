import AppKit
import Combine
import Foundation
@testable import TablePro
import TableProConnectionLibrary
import TableProEditorKit
import TableProTestSupport
import Testing

@Suite("Main split view background pane synchronization", .serialized)
@MainActor
struct MainSplitViewControllerPaneSynchronizationTests {
    @Test("A connection completed in the background mounts content when selected")
    func backgroundConnectionCompletionMountsContentWhenSelected() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.injectSession(status: .connecting, driver: false)
        harness.controller.refreshFromActiveSessions()
        harness.injectSession(status: .connected, driver: true)
        harness.controller.refreshFromActiveSessions()

        let coordinator = try #require(harness.background.sessionState?.coordinator)
        #expect(harness.controller.workspaces.selectedConnectionId == harness.foreground.connectionId)
        #expect(harness.background.phase == .connected)
        #expect(harness.background.panes.renderedKey?.pane == .content)
        #expect(!coordinator.isActivated)
        #expect(coordinator.commandActions == nil)

        harness.controller.workspaces.select(harness.background.connectionId)
        harness.settle { coordinator.isActivated }

        #expect(harness.controller.currentPane == .content)
        #expect(coordinator.isActivated)
        #expect(coordinator.commandActions != nil)
    }

    @Test("A connect that fails in the background renders the unavailable pane")
    func backgroundConnectFailureRendersUnavailablePane() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.controller.transition(to: .connecting, for: harness.background.connectionId)
        #expect(harness.background.panes.renderedKey?.pane == .connecting)

        let failure = ConnectionUnavailableReason.failed(ConnectionFailureInfo(message: "refused"))
        harness.controller.transition(to: .unavailable(failure), for: harness.background.connectionId)

        #expect(harness.background.phase == .unavailable(failure))
        #expect(harness.background.panes.renderedKey?.pane == .unavailable(failure))
    }

    @Test("A session lost in the background renders the disconnected pane, never the empty one")
    func backgroundSessionLossRendersDisconnectedPane() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.injectSession(status: .connected, driver: true)
        harness.controller.refreshFromActiveSessions()
        #expect(harness.background.panes.renderedKey?.pane == .content)

        DatabaseManager.shared.removeSession(for: harness.background.connectionId)
        harness.controller.refreshFromActiveSessions()

        #expect(harness.background.phase == .unavailable(.disconnected(nil)))
        #expect(harness.background.panes.renderedKey?.pane == .unavailable(.disconnected(nil)))
    }

    /// A tunnel drop used to nil the driver and swap the rows for the connecting card. The loop keeps
    /// the driver, so the content stays and only the reconnecting state comes and goes over it.
    @Test("A reconnect in the background keeps the content and its driver while the loop redials")
    func backgroundReconnectKeepsTheContent() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let connectionId = harness.background.connectionId

        let driver = harness.injectSession(status: .connected, driver: true)
        harness.controller.refreshFromActiveSessions()
        let coordinator = try #require(harness.background.sessionState?.coordinator)

        let progress = ConnectionRecoveryProgress(attempt: 1, cause: "The SSH tunnel closed.")
        DatabaseManager.shared.markSessionRecovering(connectionId, progress: progress)
        harness.controller.refreshFromActiveSessions()
        #expect(harness.background.phase == .connected)
        #expect(harness.background.panes.renderedKey?.pane == .content)
        #expect(harness.background.session?.recovery == progress)
        #expect(harness.background.session?.driver === driver)
        #expect(ConnectionStatusResolver.status(of: harness.background) == .reconnecting(attempt: 1, of: 10))

        DatabaseManager.shared.markSessionLive(connectionId)
        harness.controller.refreshFromActiveSessions()
        #expect(harness.background.phase == .connected)
        #expect(harness.background.panes.renderedKey?.pane == .content)
        #expect(harness.background.session?.recovery == nil)
        #expect(harness.background.session?.driver === driver)
        #expect(harness.background.sessionState?.coordinator === coordinator, "the tabs survived the outage")
        #expect(ConnectionStatusResolver.status(of: harness.background) == .connected)
    }

    @Test("Cancel on the reconnecting bar stops the loop and leaves the lost state with Reconnect")
    func cancellingTheLoopLeavesTheLostState() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let connectionId = harness.background.connectionId
        harness.controller.workspaces.select(connectionId)

        harness.injectSession(status: .connected, driver: true)
        harness.controller.refreshFromActiveSessions()
        DatabaseManager.shared.beginRecovery(for: connectionId, cause: .transportClosed("The SSH tunnel closed."))
        harness.controller.refreshFromActiveSessions()
        #expect(harness.controller.menuConnectionAction == .cancel)
        #expect(harness.controller.menuConnectionActionTitle == "Stop Reconnecting")
        #expect(harness.controller.canDisconnect)

        harness.controller.performConnectionAction(.cancel, for: connectionId)
        harness.controller.refreshFromActiveSessions()

        #expect(DatabaseManager.shared.recoveryLoops[connectionId] == nil)
        guard case .unavailable(.disconnected(let info)) = harness.background.phase else {
            Issue.record("expected the lost state, got \(harness.background.phase)")
            return
        }
        #expect(info?.failureReason == "Reconnecting was cancelled.")
        #expect(ConnectionStatusResolver.status(of: harness.background) == .lost(cause: info?.message))
        #expect(harness.controller.menuConnectionAction == .reconnect)
        #expect(harness.controller.canDisconnect, "the driver is still held")
    }

    @Test("Repeated connected status events leave the rendered panes settled")
    func repeatedConnectedEventsLeavePanesSettled() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.injectSession(status: .connected, driver: true)
        harness.controller.refreshFromActiveSessions()
        let settled = try #require(harness.background.panes.renderedKey)
        let coordinator = try #require(harness.background.sessionState?.coordinator)

        for _ in 0..<10 {
            harness.controller.refreshFromActiveSessions()
        }

        #expect(harness.background.panes.renderedKey == settled)
        #expect(harness.background.paneRenderKey == settled)
        #expect(harness.background.sessionState?.coordinator === coordinator)
    }

    @Test("A connection adopted with a live session renders content instead of staying empty")
    func adoptedWorkspaceWithLiveSessionRendersContent() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        let adopted = TestFixtures.makeConnection(name: "Adopted")
        var session = ConnectionSession(connection: adopted, driver: MockDatabaseDriver(connection: adopted))
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: adopted.id)
        defer { DatabaseManager.shared.removeSession(for: adopted.id) }

        let workspace = try #require(
            harness.controller.adoptWorkspace(
                payload: EditorTabPayload(connectionId: adopted.id),
                autoConnect: false
            )
        )
        defer { workspace.teardown() }

        #expect(workspace.phase == .connected)
        #expect(workspace.resolvedPane == .content)
        #expect(workspace.panes.renderedKey?.pane == .content)
    }

    @Test("A closed tab reopened into a connected workspace joins its tabs and is selected")
    func reopenedTabJoinsConnectedWorkspace() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.injectSession(status: .connected, driver: true)
        harness.controller.refreshFromActiveSessions()
        let tabManager = try #require(harness.background.sessionState?.tabManager)
        tabManager.addTab(initialQuery: "SELECT 1")
        let restored = QueryTab(query: "SELECT restored")
        var adoptions = 0

        harness.background.adoptRestoredTab(restored, isStillClosed: { true }, onAdopted: { adoptions += 1 })

        #expect(tabManager.tabs.count == 2)
        #expect(tabManager.selectedTabId == restored.id)
        #expect(adoptions == 1)
    }

    @Test("A closed tab reopened before the session exists lands once, when the session is adopted")
    func reopenedTabWaitsForTheSession() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        let restored = QueryTab(query: "SELECT restored")
        var adoptions = 0
        harness.background.adoptRestoredTab(restored, isStillClosed: { true }, onAdopted: { adoptions += 1 })
        #expect(harness.background.sessionState == nil)
        #expect(adoptions == 0)

        harness.injectSession(status: .connected, driver: true)
        harness.controller.refreshFromActiveSessions()
        harness.controller.refreshFromActiveSessions()

        let tabManager = try #require(harness.background.sessionState?.tabManager)
        #expect(tabManager.tabs.map(\.id) == [restored.id])
        #expect(tabManager.selectedTabId == restored.id)
        #expect(adoptions == 1)
    }

    @Test("A queued closed tab that was reopened elsewhere while it waited is not opened again")
    func queuedReopenSkipsATabNoLongerClosed() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        var isStillClosed = true
        var adoptions = 0
        harness.background.adoptRestoredTab(
            QueryTab(query: "SELECT restored"),
            isStillClosed: { isStillClosed },
            onAdopted: { adoptions += 1 }
        )
        isStillClosed = false

        harness.injectSession(status: .connected, driver: true)
        harness.controller.refreshFromActiveSessions()

        let tabManager = try #require(harness.background.sessionState?.tabManager)
        #expect(tabManager.tabs.isEmpty)
        #expect(adoptions == 0)
    }

    @Test("Focusing a tab of the background connection selects the tab and switches the window to it")
    func focusingABackgroundTabSelectsItsConnection() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.injectSession(status: .connected, driver: true)
        harness.controller.refreshFromActiveSessions()
        let coordinator = try #require(harness.background.sessionState?.coordinator)
        coordinator.tabManager.addTab(initialQuery: "SELECT 1")
        coordinator.tabManager.addTab(initialQuery: "SELECT 2")
        let target = try #require(coordinator.tabManager.tabs.first?.id)
        #expect(coordinator.tabManager.selectedTabId != target)
        let windowId = harness.registerWindow(for: coordinator)
        defer { WindowLifecycleMonitor.shared.unregisterWindow(for: windowId) }

        #expect(FocusQueryTabTool.focus(tabId: target, among: [coordinator]))
        #expect(coordinator.tabManager.selectedTabId == target)
        #expect(harness.controller.workspaces.selectedConnectionId == harness.background.connectionId)
    }

    // MARK: - Move Tab to Connection

    @Test("A tab moved into a connected background connection lands there at once and leaves its source")
    func moveIntoConnectedWorkspaceLandsAtOnce() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.injectSession(status: .connected, driver: true)
        harness.controller.refreshFromActiveSessions()
        let target = try #require(harness.background.sessionState?.coordinator)
        target.persistence.markObservedTabs()
        target.settleTabRestore()
        let moving = QueryTab(title: "Query 1", query: "SELECT 1", tabType: .query)
        let staying = QueryTab(title: "Query 2", query: "SELECT 2", tabType: .query)
        let source = harness.makeSourceCoordinator(tabs: [moving, staying])

        /// Landing in the same call that asked for it is never "the user went back to it".
        harness.background.queueMove(PendingTabMove(tabId: moving.id, source: source) { true })

        #expect(source.tabManager.tabs.map(\.id) == [staying.id])
        #expect(target.tabManager.tabs.map(\.id) == [moving.id])
        #expect(target.tabManager.selectedTabId == moving.id)
        #expect(target.tabManager.tabs.first?.content.query == "SELECT 1")
        #expect(target.tabManager.tabs.first?.tableContext.databaseName == harness.backgroundConnection.database)
    }

    @Test("A tab moved into a connection still connecting stays in its source until its restore has run")
    func moveIntoConnectingWorkspaceWaitsForTheSession() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let moving = QueryTab(title: "Query 1", query: "SELECT 1", tabType: .query)
        let source = harness.makeSourceCoordinator(tabs: [moving])

        harness.background.queueMove(PendingTabMove(tabId: moving.id, source: source) { false })

        #expect(harness.background.sessionState == nil)
        #expect(source.tabManager.tabs.map(\.id) == [moving.id])

        harness.injectSession(status: .connected, driver: true)
        harness.controller.refreshFromActiveSessions()

        let target = try #require(harness.background.sessionState?.coordinator)
        #expect(source.tabManager.tabs.map(\.id) == [moving.id])
        #expect(target.tabManager.tabs.isEmpty)

        target.persistence.markObservedTabs()
        target.settleTabRestore()

        #expect(source.tabManager.tabs.isEmpty)
        #expect(target.tabManager.tabs.map(\.id) == [moving.id])
    }

    @Test("A queued move is dropped when the connect it waits on fails")
    func queuedMoveIsDroppedWhenTheConnectFails() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let moving = QueryTab(title: "Query 1", query: "SELECT 1", tabType: .query)
        let source = harness.makeSourceCoordinator(tabs: [moving])
        let attempt = UUID()
        harness.background.attemptToken = attempt
        harness.background.queueMove(PendingTabMove(tabId: moving.id, source: source) { false })

        harness.controller.finishAttempt(
            attempt,
            for: harness.background.connectionId,
            outcome: .failed(ConnectionFailureInfo(message: "refused"))
        )
        harness.injectSession(status: .connected, driver: true)
        harness.controller.refreshFromActiveSessions()

        let target = try #require(harness.background.sessionState?.coordinator)
        target.persistence.markObservedTabs()
        target.settleTabRestore()
        #expect(source.tabManager.tabs.map(\.id) == [moving.id])
        #expect(target.tabManager.tabs.isEmpty)
    }

    @Test("A queued move is dropped when its connect is cancelled")
    func queuedMoveIsDroppedWhenTheConnectIsCancelled() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let moving = QueryTab(title: "Query 1", query: "SELECT 1", tabType: .query)
        let source = harness.makeSourceCoordinator(tabs: [moving])
        harness.background.queueMove(PendingTabMove(tabId: moving.id, source: source) { false })

        harness.controller.cancelConnectionAttempt(for: harness.background.connectionId)
        harness.injectSession(status: .connected, driver: true)
        harness.controller.refreshFromActiveSessions()

        let target = try #require(harness.background.sessionState?.coordinator)
        target.persistence.markObservedTabs()
        target.settleTabRestore()
        #expect(source.tabManager.tabs.map(\.id) == [moving.id])
        #expect(target.tabManager.tabs.isEmpty)
    }

    /// Move to a slow connection, then elsewhere, then back. The first move finishing late must not
    /// take the tab away from where the user last put it.
    @Test("A queued move superseded by a later move of the same tab never lands")
    func supersededMoveNeverLands() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let moving = QueryTab(title: "Query 1", query: "SELECT 1", tabType: .query)
        let source = harness.makeSourceCoordinator(tabs: [moving])
        let elsewhere = SessionStateFactory.create(
            connection: TestFixtures.makeConnection(name: "Elsewhere"),
            payload: nil
        ).coordinator
        defer { elsewhere.teardown() }

        source.persistence.markObservedTabs()
        elsewhere.persistence.markObservedTabs()
        let stale = PendingTabMove(tabId: moving.id, source: source) { false }
        harness.background.queueMove(stale)
        let away = PendingTabMove(tabId: moving.id, source: source) { false }
        #expect(away.land(in: elsewhere, afterWaiting: false))
        let back = PendingTabMove(tabId: moving.id, source: elsewhere) { false }
        #expect(back.land(in: source, afterWaiting: false))
        #expect(stale.isSuperseded)

        harness.injectSession(status: .connected, driver: true)
        harness.controller.refreshFromActiveSessions()

        let target = try #require(harness.background.sessionState?.coordinator)
        target.persistence.markObservedTabs()
        target.settleTabRestore()
        #expect(source.tabManager.tabs.map(\.id) == [moving.id])
        #expect(target.tabManager.tabs.isEmpty)
    }

    @Test("A queued move is refused when the user has gone back to the tab")
    func queuedMoveIsRefusedWhenTheUserReturned() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let moving = QueryTab(title: "Query 1", query: "SELECT 1", tabType: .query)
        let source = harness.makeSourceCoordinator(tabs: [moving])
        var sourceOnScreen = false
        harness.background.queueMove(PendingTabMove(tabId: moving.id, source: source) { sourceOnScreen })

        sourceOnScreen = true
        harness.injectSession(status: .connected, driver: true)
        harness.controller.refreshFromActiveSessions()

        let target = try #require(harness.background.sessionState?.coordinator)
        target.persistence.markObservedTabs()
        target.settleTabRestore()
        #expect(source.tabManager.tabs.map(\.id) == [moving.id])
        #expect(target.tabManager.tabs.isEmpty)
    }

    @Test("A file tab is refused when the target already has that file open")
    func moveIsRefusedWhenTheTargetHoldsTheFile() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.injectSession(status: .connected, driver: true)
        harness.controller.refreshFromActiveSessions()
        let target = try #require(harness.background.sessionState?.coordinator)
        target.persistence.markObservedTabs()
        target.settleTabRestore()
        let url = URL(fileURLWithPath: "/tmp/move-tab-same-file.sql")
        target.tabManager.addTab(initialQuery: "SELECT 0", sourceFileURL: url)
        var moving = QueryTab(title: "move-tab-same-file.sql", query: "SELECT 1", tabType: .query)
        moving.content.sourceFileURL = url
        let source = harness.makeSourceCoordinator(tabs: [moving])

        harness.background.queueMove(PendingTabMove(tabId: moving.id, source: source) { false })

        #expect(source.tabManager.tabs.map(\.id) == [moving.id])
        #expect(target.tabManager.tabs.count == 1)
        #expect(!target.tabManager.tabs.contains { $0.id == moving.id })
    }

    @Test("Moving a connection's last tab clears its saved tabs")
    func movingTheLastTabClearsTheSavedSet() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.injectSession(status: .connected, driver: true)
        harness.controller.refreshFromActiveSessions()
        let target = try #require(harness.background.sessionState?.coordinator)
        target.persistence.markObservedTabs()
        target.settleTabRestore()
        let moving = QueryTab(title: "Query 1", query: "SELECT 1", tabType: .query)
        let source = harness.makeSourceCoordinator(tabs: [moving])
        defer { TabDiskActor.clearSync(connectionId: harness.foregroundConnection.id) }
        source.persistence.markObservedTabs()
        source.persistence.saveNowSync(tabs: [moving], selectedTabId: moving.id)

        harness.background.queueMove(PendingTabMove(tabId: moving.id, source: source) { false })

        #expect(target.tabManager.tabs.map(\.id) == [moving.id])
        let saved = await TabDiskActor.shared.load(connectionId: harness.foregroundConnection.id)
        #expect(saved == nil || saved?.tabs.isEmpty == true)
    }

    @Test("Moving a window's last tab keeps the saved tabs another window of that connection holds")
    func movingTheLastTabKeepsTabsHeldElsewhere() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.injectSession(status: .connected, driver: true)
        harness.controller.refreshFromActiveSessions()
        let target = try #require(harness.background.sessionState?.coordinator)
        target.persistence.markObservedTabs()
        target.settleTabRestore()
        let moving = QueryTab(title: "Query 1", query: "SELECT 1", tabType: .query)
        let held = QueryTab(title: "Query 2", query: "SELECT 2", tabType: .query)
        let source = harness.makeSourceCoordinator(tabs: [moving])
        let otherWindow = SessionStateFactory.create(connection: harness.foregroundConnection, payload: nil)
        otherWindow.tabManager.tabs = [held]
        defer {
            otherWindow.coordinator.teardown()
            TabDiskActor.clearSync(connectionId: harness.foregroundConnection.id)
        }
        source.persistence.markObservedTabs()
        source.persistence.saveNowSync(tabs: [moving, held], selectedTabId: moving.id)

        harness.background.queueMove(PendingTabMove(tabId: moving.id, source: source) { false })

        let connectionId = harness.foregroundConnection.id
        try await waitUntil {
            await TabDiskActor.shared.load(connectionId: connectionId)?.tabs.contains { $0.id == moving.id } != true
        }
        let saved = await TabDiskActor.shared.load(connectionId: connectionId)
        #expect(saved?.tabs.map(\.id) == [held.id])
    }

    /// A session state kept through an outage still has a settled coordinator, which is not a live
    /// connection: the tab must wait for the reconnect rather than land in a connection that is down.
    @Test("A tab moved into a connection that dropped waits for it to come back")
    func moveIntoDroppedConnectionWaitsForTheReconnect() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.injectSession(status: .connected, driver: true)
        harness.controller.refreshFromActiveSessions()
        let target = try #require(harness.background.sessionState?.coordinator)
        target.persistence.markObservedTabs()
        target.settleTabRestore()
        harness.controller.transition(to: .unavailable(.disconnected(nil)), for: harness.background.connectionId)
        let moving = QueryTab(title: "Query 1", query: "SELECT 1", tabType: .query)
        let source = harness.makeSourceCoordinator(tabs: [moving])

        harness.background.queueMove(PendingTabMove(tabId: moving.id, source: source) { false })

        #expect(source.tabManager.tabs.map(\.id) == [moving.id])
        #expect(target.tabManager.tabs.isEmpty)

        harness.controller.refreshFromActiveSessions()

        #expect(source.tabManager.tabs.isEmpty)
        #expect(harness.background.sessionState?.coordinator.tabManager.tabs.map(\.id) == [moving.id])
    }

    /// A connection first opened onto one table or query never read its saved tabs. The move reads
    /// them first, so the target can write the tab before the source lets it go.
    @Test("A target that has not read its saved tabs reads them, then takes the tab")
    func targetReadsItsSavedTabsBeforeTakingTheMove() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.injectSession(status: .connected, driver: true)
        harness.controller.refreshFromActiveSessions()
        let target = try #require(harness.background.sessionState?.coordinator)
        defer { TabDiskActor.clearSync(connectionId: harness.backgroundConnection.id) }
        target.settleTabRestore()
        let moving = QueryTab(title: "Query 1", query: "SELECT 1", tabType: .query)
        let source = harness.makeSourceCoordinator(tabs: [moving])

        harness.background.queueMove(PendingTabMove(tabId: moving.id, source: source) { false })

        #expect(source.tabManager.tabs.map(\.id) == [moving.id])
        try await waitUntil { !target.tabManager.tabs.isEmpty }
        #expect(target.persistence.hasObservedTabs)
        #expect(target.tabManager.tabs.map(\.id) == [moving.id])
        #expect(source.tabManager.tabs.isEmpty)
    }

    /// Closing the moved tab selects its neighbour without that editor mounting, so the live caret
    /// still belongs to the moved tab when the source saves.
    @Test("The moved tab's caret is not written into the tab left selected")
    func movedCaretDoesNotLeakIntoTheNeighbour() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.injectSession(status: .connected, driver: true)
        harness.controller.refreshFromActiveSessions()
        let target = try #require(harness.background.sessionState?.coordinator)
        target.persistence.markObservedTabs()
        target.settleTabRestore()
        let moving = QueryTab(title: "Query 1", query: "SELECT 1 FROM moved", tabType: .query)
        let staying = QueryTab(title: "Query 2", query: "SELECT 2", tabType: .query)
        let source = harness.makeSourceCoordinator(tabs: [moving, staying])
        source.cursorPositions = [CursorPosition(range: NSRange(location: 12, length: 0))]

        harness.background.queueMove(PendingTabMove(tabId: moving.id, source: source) { false })

        let neighbour = try #require(source.tabManager.selectedTab)
        #expect(neighbour.id == staying.id)
        #expect(source.enrichedForPersistence(neighbour).restoredCursorOffset == nil)
        #expect(target.tabManager.tabs.first?.restoredCursorOffset == 12)
    }

    @Test("A landed tab is written to the target's saved set at once")
    func landedTabIsSavedByTheTarget() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.injectSession(status: .connected, driver: true)
        harness.controller.refreshFromActiveSessions()
        let target = try #require(harness.background.sessionState?.coordinator)
        defer { TabDiskActor.clearSync(connectionId: harness.backgroundConnection.id) }
        target.persistence.markObservedTabs()
        target.settleTabRestore()
        let moving = QueryTab(title: "Query 1", query: "SELECT 1", tabType: .query)
        let source = harness.makeSourceCoordinator(tabs: [moving])

        harness.background.queueMove(PendingTabMove(tabId: moving.id, source: source) { false })

        let saved = await TabDiskActor.shared.load(connectionId: harness.backgroundConnection.id)
        #expect(saved?.tabs.map(\.id) == [moving.id])
        #expect(saved?.tabs.first?.query == "SELECT 1")
    }

    @Test("A connection reopened without its connect stays not connected when its window activates")
    func reopenedWithoutConnectStaysNotConnected() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        #expect(harness.controller.workspaces.selectedConnectionId == harness.foreground.connectionId)

        harness.controller.startActivationConnectIfNeeded()

        #expect(harness.foreground.phase == .idle)
        #expect(harness.foreground.attemptToken == nil)
        #expect(harness.foreground.resolvedPane == .unavailable(.notConnected))
    }

    @Test("A connect request leaves a workspace the user canceled alone")
    func requestedConnectLeavesACanceledWorkspaceAlone() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.controller.transition(to: .unavailable(.cancelled), for: harness.foreground.connectionId)

        harness.controller.startActivationConnectIfNeeded(requested: true)

        #expect(harness.foreground.phase == .unavailable(.cancelled))
        #expect(harness.foreground.attemptToken == nil)
    }

    @Test("A connect request reaches a reopened workspace that was not opened to dial")
    func requestedConnectReachesAnIdleWorkspace() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.foreground.payloadConnection?.preConnectScript = "true"

        harness.controller.startActivationConnectIfNeeded(requested: true)

        // A script needs consent, so the request settles on Not Connected instead of dialing.
        #expect(harness.foreground.phase == .unavailable(.notConnected))
        #expect(harness.foreground.attemptToken == nil)
    }

    @Test("Reconnecting only when idle shows a connecting connection and leaves its attempt alone")
    func reconnectIfIdleLeavesAConnectingWorkspaceAlone() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let attempt = UUID()
        harness.controller.transition(to: .connecting, for: harness.background.connectionId)
        harness.background.attemptToken = attempt

        harness.controller.reconnectWorkspaceIfIdle(harness.background.connectionId)

        #expect(harness.controller.workspaces.selectedConnectionId == harness.background.connectionId)
        #expect(harness.background.attemptToken == attempt)
        #expect(harness.background.phase == .connecting)
    }

    // MARK: - Connection status

    /// Nothing outside the window heard a phase move, so the rail kept painting from the session
    /// alone and could not tell a failed connect from a disconnect.
    @Test("A phase change is announced once, naming its connection")
    func phaseChangeIsAnnounced() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        var announced: [UUID] = []
        let subscription = AppEvents.shared.connectionPhaseChanged.sink { announced.append($0) }
        defer { subscription.cancel() }

        let failure = ConnectionUnavailableReason.failed(ConnectionFailureInfo(message: "refused"))
        harness.controller.transition(to: .unavailable(failure), for: harness.background.connectionId)
        harness.controller.transition(to: .unavailable(failure), for: harness.background.connectionId)

        #expect(announced.filter { $0 == harness.background.connectionId }.count == 1)
    }

    @Test("A session the loop is redialing keeps its content and carries its progress")
    func redialingSessionKeepsItsContent() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.injectSession(status: .connected, driver: true)
        harness.controller.refreshFromActiveSessions()
        let progress = ConnectionRecoveryProgress(attempt: 2, cause: "The SSH tunnel closed.")
        harness.injectSession(status: .connecting, driver: true, liveness: .recovering, recovery: progress)
        harness.controller.refreshFromActiveSessions()

        #expect(harness.background.phase == .connected)
        #expect(harness.background.panes.renderedKey?.pane == .content)
        #expect(harness.background.session?.recovery == progress)
        #expect(ConnectionStatusResolver.status(of: harness.background) == .reconnecting(attempt: 2, of: 10))
    }

    @Test("The menu bar's connection command follows the state", arguments: [
        (ConnectionWindowPhase.unavailable(.notConnected), ConnectionStatusAction?.some(.connect), "Connect"),
        (.unavailable(.failed(ConnectionFailureInfo(message: "refused"))), .connect, "Connect"),
        (.connecting, .cancel, "Stop Connecting"),
        (.connected, nil, "Reconnect"),
    ])
    func menuBarCommandFollowsTheState(
        _ phase: ConnectionWindowPhase,
        _ action: ConnectionStatusAction?,
        _ title: String
    ) throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.controller.workspaces.select(harness.background.connectionId)

        harness.controller.transition(to: phase, for: harness.background.connectionId)

        #expect(harness.controller.menuConnectionAction == action)
        #expect(harness.controller.menuConnectionActionTitle == title)
        #expect(harness.controller.canReconnect == (action != nil))
        let item = NSMenuItem(title: "Reconnect", action: #selector(MainSplitViewController.retryConnection), keyEquivalent: "")
        _ = harness.controller.validateMenuItem(item)
        #expect(item.title == title)
    }

    /// Disconnect needed `.connected`, so a session the monitor had given up on could only be closed.
    @Test("Disconnect stays available over a lost session that still holds its driver")
    func lostSessionCanBeDisconnected() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.controller.workspaces.select(harness.background.connectionId)

        let info = ConnectionFailureInfo(message: "timed out")
        harness.injectSession(status: .connected, driver: true, liveness: .unreachable(info))
        harness.controller.refreshFromActiveSessions()

        #expect(harness.background.phase == .unavailable(.disconnected(info)))
        #expect(harness.controller.canDisconnect)
        #expect(harness.controller.menuConnectionAction == .reconnect)

        DatabaseManager.shared.removeSession(for: harness.background.connectionId)
        harness.controller.refreshFromActiveSessions()
        #expect(!harness.controller.canDisconnect, "nothing is left to end once the entry has gone")
    }

    @Test("Stopping a dial from a menu cancels the attempt at once")
    func stopConnectingCancelsTheAttempt() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.controller.transition(to: .connecting, for: harness.background.connectionId)
        harness.controller.performConnectionAction(.cancel, for: harness.background.connectionId)

        #expect(harness.background.phase == .unavailable(.cancelled))
        #expect(harness.background.attemptToken == nil)
    }

    @Test("The inspector says Connecting while the connection dials")
    func inspectorSaysConnecting() {
        #expect(TrailingPaneUnavailableView.Reason.forPane(.connecting) == .connecting)
        #expect(TrailingPaneUnavailableView.Reason.forPane(.unavailable(.notConnected)) == .notConnected)
        #expect(TrailingPaneUnavailableView.Reason.forPane(.empty) == .notConnected)
    }

    /// One window hosting two connections, with the second one in the background. Every case here
    /// asks what that background workspace's panes hold, which is the state the window shows the
    /// moment the user switches to it.
    @MainActor
    private struct Harness {
        let controller: MainSplitViewController
        let foreground: ConnectionWorkspace
        let background: ConnectionWorkspace
        let foregroundConnection: DatabaseConnection
        let backgroundConnection: DatabaseConnection
        private let window: NSWindow

        init() throws {
            foregroundConnection = TestFixtures.makeConnection(name: "Foreground")
            backgroundConnection = TestFixtures.makeConnection(name: "Background")
            foreground = Self.makeWorkspace(connection: foregroundConnection, phase: .idle)
            background = Self.makeWorkspace(connection: backgroundConnection, phase: .connecting)

            controller = MainSplitViewController(payload: nil, sessionState: nil, adopting: foreground)
            controller.workspaces.insert(background, select: false)

            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.orderFront(nil)
        }

        @discardableResult
        func injectSession(
            status: ConnectionStatus,
            driver: Bool,
            liveness: ConnectionLiveness = .live,
            recovery: ConnectionRecoveryProgress? = nil
        ) -> MockDatabaseDriver? {
            let mock = driver ? MockDatabaseDriver(connection: backgroundConnection) : nil
            var session = ConnectionSession(connection: backgroundConnection, driver: mock)
            session.status = status
            session.liveness = liveness
            session.recovery = recovery
            DatabaseManager.shared.injectSession(session, for: backgroundConnection.id)
            return mock
        }

        /// The foreground connection's coordinator holding `tabs`, the first one selected. Its
        /// workspace owns it, so `tearDown` releases it with the rest.
        func makeSourceCoordinator(tabs: [QueryTab]) -> MainContentCoordinator {
            let state = SessionStateFactory.create(connection: foregroundConnection, payload: nil)
            state.tabManager.tabs = tabs
            state.tabManager.selectedTabId = tabs.first?.id
            foreground.sessionState = state
            return state.coordinator
        }

        func registerWindow(for coordinator: MainContentCoordinator) -> UUID {
            let windowId = UUID()
            coordinator.windowId = windowId
            WindowLifecycleMonitor.shared.register(
                window: window,
                connectionId: coordinator.connectionId,
                windowId: windowId
            )
            return windowId
        }

        /// SwiftUI mounts a pane on the next layout pass, so a test that asks whether it mounted has
        /// to let the run loop reach one.
        func settle(until isSatisfied: () -> Bool) {
            let deadline = Date(timeIntervalSinceNow: 2)
            while !isSatisfied(), Date() < deadline {
                window.contentView?.layoutSubtreeIfNeeded()
                controller.view.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            }
        }

        func tearDown() {
            window.orderOut(nil)
            window.contentViewController = nil
            background.teardown()
            foreground.teardown()
            DatabaseManager.shared.removeSession(for: backgroundConnection.id)
        }

        private static func makeWorkspace(
            connection: DatabaseConnection,
            phase: ConnectionWindowPhase
        ) -> ConnectionWorkspace {
            ConnectionWorkspace(
                connectionId: connection.id,
                payload: nil,
                autoConnect: false,
                payloadConnection: connection,
                session: nil,
                sessionState: nil,
                trailingPaneState: nil,
                phase: phase
            )
        }
    }
}
