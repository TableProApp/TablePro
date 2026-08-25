//
//  ConnectionWorkspaceContainersTests.swift
//  TableProTests
//

import Combine
import Foundation
@testable import TablePro
import Testing

@Suite("Connection workspace containers")
@MainActor
struct ConnectionWorkspaceContainersTests {
    private func makeWorkspace() -> ConnectionWorkspace {
        ConnectionWorkspace(
            connectionId: UUID(),
            payload: nil,
            autoConnect: false,
            payloadConnection: nil,
            session: nil,
            sessionState: nil,
            rightPanelState: nil,
            phase: .idle
        )
    }

    @Test("A container the connection opens stays open")
    func openedContainerIsHeld() {
        let workspace = makeWorkspace()
        workspace.openContainer("app")
        workspace.openContainer("logs")

        #expect(workspace.openedContainers == ["app", "logs"])
    }

    /// An engine that switches neither database nor schema names no container, and its connection
    /// has exactly one entry keyed by the empty string. Recording that would give it a second.
    @Test("An unnamed container is not recorded")
    func emptyContainerIsIgnored() {
        let workspace = makeWorkspace()
        workspace.openContainer("")

        #expect(workspace.openedContainers.isEmpty)
    }

    @Test("Closing a container leaves the others open")
    func closingLeavesTheRest() {
        let workspace = makeWorkspace()
        workspace.openContainer("app")
        workspace.openContainer("logs")

        workspace.closeContainer("logs")

        #expect(workspace.openedContainers == ["app"])
    }

    /// Every rail listens to the same events the workspace does, and Combine delivers them in
    /// subscription order, so a rail that reloaded first would list the set as it was a moment ago.
    /// The workspace publishing for itself is what makes the order stop mattering.
    @Test("Opening a container tells the open strips to reload")
    func openingPublishes() {
        let workspace = makeWorkspace()
        var received = 0
        let cancellable = AppEvents.shared.connectionWindowsChanged.sink { received += 1 }
        defer { cancellable.cancel() }

        workspace.openContainer("app")
        workspace.openContainer("app")
        workspace.closeContainer("app")
        workspace.closeContainer("app")

        #expect(received == 2)
    }

    /// Releasing the workspace writes `session = nil`, and its observer would otherwise record the
    /// container again from the session the manager has not dropped yet, on a workspace no window
    /// hosts any more.
    @Test("Closing the connection takes its containers with it and takes no more")
    func teardownClearsContainers() {
        let workspace = makeWorkspace()
        workspace.openContainer("app")

        workspace.teardown()
        workspace.openContainer("logs")

        #expect(workspace.openedContainers.isEmpty)
    }
}
