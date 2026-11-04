//
//  TwoConnectionWindow.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro

// One window hosting two connected connections, each with its coordinator. Agent sessions live in a
// registry of its own, since stopping a shared one writes to the app's real conversation store.
@MainActor
internal struct TwoConnectionWindow {
    let controller: MainSplitViewController
    let foreground: ConnectionWorkspace
    let background: ConnectionWorkspace
    let agentSessions: AgentSessionRegistry
    let window: NSWindow
    private let registryDirectory: URL

    init() {
        registryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoConnectionWindow-\(UUID().uuidString)", isDirectory: true)
        agentSessions = AgentSessionRegistry(store: AgentSessionStore(directory: registryDirectory))
        let foregroundConnection = TestFixtures.makeConnection(name: "Foreground")
        let backgroundConnection = TestFixtures.makeConnection(name: "Background")
        foreground = Self.makeWorkspace(connection: foregroundConnection, agentSessions: agentSessions)
        background = Self.makeWorkspace(connection: backgroundConnection, agentSessions: agentSessions)
        Self.injectSession(for: foregroundConnection)
        Self.injectSession(for: backgroundConnection)

        controller = MainSplitViewController(payload: nil, sessionState: nil, adopting: foreground)
        controller.workspaces.insert(background, select: false)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        controller.refreshFromActiveSessions()
    }

    func coordinator(of workspace: ConnectionWorkspace) throws -> MainContentCoordinator {
        guard let coordinator = workspace.sessionState?.coordinator else {
            throw TwoConnectionWindowError.noCoordinator(workspace.connectionId)
        }
        return coordinator
    }

    @discardableResult
    func addSelectedTab(to workspace: ConnectionWorkspace) throws -> QueryTab {
        let coordinator = try coordinator(of: workspace)
        let tab = QueryTab(title: "Query", tabType: .query)
        coordinator.tabManager.tabs.append(tab)
        coordinator.tabManager.selectedTabId = tab.id
        return tab
    }

    func registerWindow(for coordinator: MainContentCoordinator) -> UUID {
        let windowId = UUID()
        coordinator.windowId = windowId
        WindowLifecycleMonitor.shared.register(window: window, connectionId: coordinator.connectionId, windowId: windowId)
        return windowId
    }

    func tearDown() {
        for workspace in [foreground, background] where workspace.contentMode == .agent {
            controller.setContentMode(.browse, for: workspace.connectionId)
        }
        if controller.isSidebarCollapsed { controller.toggleSidebar(nil) }
        if controller.isTrailingPaneOpen { controller.hideTrailingPane() }
        for session in agentSessions.sessions {
            agentSessions.removeSession(id: session.id)
        }
        window.orderOut(nil)
        window.contentViewController = nil
        background.teardown()
        foreground.teardown()
        DatabaseManager.shared.removeSession(for: foreground.connectionId)
        DatabaseManager.shared.removeSession(for: background.connectionId)
        try? FileManager.default.removeItem(at: registryDirectory)
    }

    private static func injectSession(for connection: DatabaseConnection) {
        var session = ConnectionSession(connection: connection, driver: MockDatabaseDriver(connection: connection))
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
    }

    private static func makeWorkspace(
        connection: DatabaseConnection,
        agentSessions: AgentSessionRegistry
    ) -> ConnectionWorkspace {
        ConnectionWorkspace(
            connectionId: connection.id,
            payload: nil,
            autoConnect: false,
            payloadConnection: connection,
            session: nil,
            sessionState: nil,
            trailingPaneState: nil,
            phase: .connecting,
            agentSessions: agentSessions
        )
    }
}

internal enum TwoConnectionWindowError: Error {
    case noCoordinator(UUID)
}
