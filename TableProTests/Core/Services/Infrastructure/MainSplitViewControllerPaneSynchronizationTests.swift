import AppKit
import Foundation
@testable import TablePro
import Testing

@Suite("Main split view background pane synchronization", .serialized)
@MainActor
struct MainSplitViewControllerPaneSynchronizationTests {
    @Test("A connection completed in the background mounts content when selected")
    func backgroundConnectionCompletionMountsContentWhenSelected() throws {
        let foregroundId = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000002545"))
        let backgroundId = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000002546"))
        let foregroundConnection = TestFixtures.makeConnection(id: foregroundId, name: "Foreground")
        let backgroundConnection = TestFixtures.makeConnection(id: backgroundId, name: "Background")

        var pendingSession = ConnectionSession(connection: backgroundConnection)
        pendingSession.status = .connecting
        DatabaseManager.shared.injectSession(pendingSession, for: backgroundId)

        let foregroundWorkspace = makeWorkspace(connection: foregroundConnection, phase: .idle)
        let backgroundWorkspace = makeWorkspace(connection: backgroundConnection, phase: .connecting)
        let controller = MainSplitViewController(
            payload: nil,
            sessionState: nil,
            adopting: foregroundWorkspace
        )
        controller.workspaces.insert(backgroundWorkspace, select: false)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)

        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            backgroundWorkspace.teardown()
            foregroundWorkspace.teardown()
            DatabaseManager.shared.removeSession(for: backgroundId)
        }

        var connectedSession = ConnectionSession(
            connection: backgroundConnection,
            driver: MockDatabaseDriver(connection: backgroundConnection)
        )
        connectedSession.status = .connected
        DatabaseManager.shared.injectSession(connectedSession, for: backgroundId)
        controller.refreshFromActiveSessions()

        let coordinator = try #require(backgroundWorkspace.sessionState?.coordinator)
        #expect(controller.workspaces.selectedConnectionId == foregroundId)
        #expect(backgroundWorkspace.phase == .connected)
        #expect(!coordinator.isActivated)
        #expect(coordinator.commandActions == nil)

        controller.workspaces.select(backgroundId)

        let deadline = Date(timeIntervalSinceNow: 2)
        while !coordinator.isActivated, Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }

        #expect(controller.currentPane == .content)
        #expect(coordinator.isActivated)
        #expect(coordinator.commandActions != nil)
    }

    private func makeWorkspace(
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
