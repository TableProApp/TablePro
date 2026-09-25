//
//  OffscreenConnectionWindow.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

@MainActor
internal struct OffscreenConnectionWindow {
    let controller: TabWindowController
    let window: NSWindow
    let split: MainSplitViewController
    let workspace: ConnectionWorkspace
    private let hasInjectedSession: Bool

    init(size: CGSize, connectedTo connection: DatabaseConnection? = nil) throws {
        let subject = connection ?? TestFixtures.makeConnection(name: "Offscreen window")
        workspace = ConnectionWorkspace(
            connectionId: subject.id,
            payload: nil,
            autoConnect: false,
            payloadConnection: subject,
            session: nil,
            sessionState: nil,
            trailingPaneState: nil,
            phase: .connecting
        )
        controller = TabWindowController(
            payload: EditorTabPayload(connectionId: subject.id),
            pinnedWindowSize: size,
            adopting: workspace
        )
        let built = try #require(controller.window)
        window = built
        split = try #require(built.contentViewController as? MainSplitViewController)
        hasInjectedSession = connection != nil

        if hasInjectedSession {
            var session = ConnectionSession(connection: subject, driver: MockDatabaseDriver(connection: subject))
            session.status = .connected
            DatabaseManager.shared.injectSession(session, for: subject.id)
            split.refreshFromActiveSessions()
        }

        let toolbar = ContextValidatedToolbar(
            identifier: NSToolbar.Identifier("com.TablePro.tests.offscreen.\(UUID().uuidString)")
        )
        let owner = MainWindowToolbar(managedToolbar: toolbar)
        toolbar.autosavesConfiguration = false
        split.toolbarOwner = owner
        split.pointToolbar(at: nil)
        resetPaneLayout()
    }

    var themeFrame: NSView? {
        window.contentView?.superview
    }

    func setInspectorOpen(_ isOpen: Bool) {
        split.inspectorSplitItem.isCollapsed = !isOpen
        window.layoutIfNeeded()
    }

    func resetPaneLayout() {
        split.sidebarSplitItem.isCollapsed = false
        setInspectorOpen(false)
    }

    func tearDown() {
        resetPaneLayout()
        split.invalidateToolbar()
        window.delegate = nil
        window.contentViewController = nil
        workspace.teardown()
        if hasInjectedSession {
            DatabaseManager.shared.removeSession(for: workspace.connectionId)
        }
    }
}
