//
//  WorkspaceSwitchKeyStateTests.swift
//  TableProTests
//
//  Switching connection inside a window is that window's key change as far as each connection's
//  coordinator is concerned: the one leaving the screen resigns, which is what schedules the
//  eviction of its row buffers.
//

import AppKit
import Foundation
@testable import TablePro
import Testing

@Suite("Workspace switch key state", .serialized)
@MainActor
struct WorkspaceSwitchKeyStateTests {
    @MainActor
    private struct Harness {
        let controller: MainSplitViewController
        let first: ConnectionWorkspace
        let second: ConnectionWorkspace
        let window: NSWindow

        init() {
            first = Self.makeWorkspace(name: "First")
            second = Self.makeWorkspace(name: "Second")
            controller = MainSplitViewController(payload: nil, sessionState: nil, adopting: first)
            controller.workspaces.insert(second, select: false)
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
        }

        func coordinator(_ workspace: ConnectionWorkspace) throws -> MainContentCoordinator {
            try #require(workspace.sessionState?.coordinator)
        }

        func tearDown() {
            window.orderOut(nil)
            window.contentViewController = nil
            first.teardown()
            second.teardown()
        }

        private static func makeWorkspace(name: String) -> ConnectionWorkspace {
            let connection = TestFixtures.makeConnection(name: name)
            return ConnectionWorkspace(
                connectionId: connection.id,
                payload: nil,
                autoConnect: false,
                payloadConnection: connection,
                session: nil,
                sessionState: SessionStateFactory.create(connection: connection, payload: nil),
                trailingPaneState: nil,
                phase: .idle
            )
        }
    }

    /// The window makes its first connection key itself, so the controller's cached coordinator was
    /// still nil at the first switch and the connection leaving the screen was never told.
    @Test("The first switch away from a window's first connection resigns it")
    func firstSwitchResignsTheFirstConnection() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let first = try harness.coordinator(harness.first)
        let second = try harness.coordinator(harness.second)
        first.handleWindowDidBecomeKey()

        harness.controller.workspaces.select(harness.second.connectionId)

        #expect(first.isKeyWindow == false)
        #expect(first.evictionTask != nil)
        #expect(second.isKeyWindow)
    }

    @Test("Switching back hands key status back")
    func switchingBackHandsItBack() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let first = try harness.coordinator(harness.first)
        let second = try harness.coordinator(harness.second)
        first.handleWindowDidBecomeKey()

        harness.controller.workspaces.select(harness.second.connectionId)
        harness.controller.workspaces.select(harness.first.connectionId)

        #expect(first.isKeyWindow)
        #expect(second.isKeyWindow == false)
    }
}
