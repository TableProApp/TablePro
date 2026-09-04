import AppKit
import Foundation
@testable import TablePro
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
    func backgroundConnectFailureRendersUnavailablePane() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.controller.transition(to: .connecting, for: harness.background.connectionId)
        #expect(harness.background.panes.renderedKey?.pane == .preparing)

        await harness.revealConnectingProgress(of: harness.background)
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

    @Test("A reconnect in the background renders connecting, returns to content, and adopts the new driver")
    func backgroundReconnectRendersConnectingThenContent() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        let first = harness.injectSession(status: .connected, driver: true)
        harness.controller.refreshFromActiveSessions()
        #expect(harness.background.panes.renderedKey?.pane == .content)
        #expect(harness.background.session?.driver === first)

        harness.injectSession(status: .connecting, driver: false)
        harness.controller.refreshFromActiveSessions()
        #expect(harness.background.phase == .connecting)
        #expect(harness.background.panes.renderedKey?.pane == .preparing)

        await harness.revealConnectingProgress(of: harness.background)
        #expect(harness.background.panes.renderedKey?.pane == .connecting)

        let replacement = harness.injectSession(status: .connected, driver: true)
        harness.controller.refreshFromActiveSessions()
        #expect(harness.background.phase == .connected)
        #expect(harness.background.panes.renderedKey?.pane == .content)
        /// A recovered tunnel hands over a session that draws identically and carries a different
        /// driver. Adopting on the phase alone is what stops the workspace holding the one the
        /// recovery already disconnected, along with its cached credentials.
        #expect(replacement !== first)
        #expect(harness.background.session?.driver === replacement)
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

    @Test("A content mode change is a different render key")
    func contentModeChangeInvalidatesTheRenderKey() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        let before = harness.foreground.paneRenderKey
        harness.foreground.contentMode = .assistant

        #expect(harness.foreground.paneRenderKey != before)
        #expect(harness.foreground.paneRenderKey.contentMode == .assistant)
    }

    /// A background workspace repainted over and over stays unmounted, which is what keeps it
    /// unactivated. Forcing the layout of a detached pane mounts it, and mounting `MainContentView`
    /// runs `markActivated()` and `setupCommandActions()` from its `onAppear`, so a background
    /// connection that only finished connecting would retain a schema provider, start periodic
    /// saves and report itself activated for a window nobody has looked at.
    @Test("Repainting a background workspace never activates it")
    func repeatedBackgroundRefreshesLeaveItUnactivated() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.injectSession(status: .connected, driver: true)
        harness.controller.refreshFromActiveSessions()
        let coordinator = try #require(harness.background.sessionState?.coordinator)

        for _ in 0..<3 {
            harness.controller.refreshPanes(of: harness.background)
        }

        #expect(!coordinator.isActivated)
        #expect(coordinator.commandActions == nil)
    }

    /// One window hosting two connections, with the second one in the background. Every case here
    /// asks what that background workspace's panes hold, which is the state the window shows the
    /// moment the user switches to it.
    @MainActor
    private struct Harness {
        let controller: MainSplitViewController
        let foreground: ConnectionWorkspace
        let background: ConnectionWorkspace
        let backgroundConnection: DatabaseConnection
        private let window: NSWindow

        init() throws {
            let foregroundConnection = TestFixtures.makeConnection(name: "Foreground")
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
        func injectSession(status: ConnectionStatus, driver: Bool) -> MockDatabaseDriver? {
            let mock = driver ? MockDatabaseDriver(connection: backgroundConnection) : nil
            var session = ConnectionSession(connection: backgroundConnection, driver: mock)
            session.status = status
            DatabaseManager.shared.injectSession(session, for: backgroundConnection.id)
            return mock
        }

        /// A connect younger than `LoadingRevealPolicy.grace` resolves to `.preparing`, so a test
        /// that asks what a dialling window reports has to say which side of the grace it means.
        /// This waits out the timer the controller arms, which is what turns `.preparing` into
        /// `.connecting` and repaints the panes.
        /// The wait suspends rather than spinning a run loop, because the reveal runs on the main
        /// actor and a synchronous test holds that actor for its whole body: no amount of run loop
        /// would let the timer's continuation in.
        func revealConnectingProgress(of workspace: ConnectionWorkspace) async {
            let deadline = Date(timeIntervalSinceNow: 5)
            while !workspace.hasOutlastedConnectGrace, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
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
                rightPanelState: nil,
                phase: phase
            )
        }
    }
}
