//
//  EditorWindowInitialFrameTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import Testing

@testable import TablePro

/// A connection window opened in the background under a pinned screenshot size came up with its
/// sidebar's top row under the titlebar and its toolbar's trailing items in the overflow menu, and
/// stayed that way. The pin resized the window from a `WindowAccessor` callback, which runs inside
/// the window's layout pass.
@Suite("Editor window initial frame", .serialized)
@MainActor
struct EditorWindowInitialFrameTests {
    private let pinnedSize = CGSize(width: 1_000, height: 700)

    /// Built through the initializer every connection window comes from, so moving the pin anywhere
    /// after construction fails here: the window then starts at its content's own size.
    @Test("A connection window starts at its pinned size, before it is ever shown")
    func connectionWindowIsBuiltAtItsPinnedSize() throws {
        try withConnectionWindow { window in
            #expect(!window.isVisible)
            #expect(window.frame.size == pinnedSize)
        }
    }

    /// The window's content view is the split view every pane hangs from, so it has to span exactly
    /// the window: the sidebar's top inset, the inspector divider and the toolbar sections that
    /// track both are all measured against it.
    @Test("A connection window's split view spans the pinned window once it is laid out")
    func splitViewSpansThePinnedWindow() throws {
        try withConnectionWindow { window in
            window.layoutIfNeeded()

            #expect(window.contentView?.frame.size == pinnedSize)
            #expect(window.contentView?.frame.origin == .zero)
        }
    }

    /// Why the pin cannot live anywhere a view reports its window from. The connection's content
    /// arrives in a pane that is already on the window, the way `refreshPanes` hands it over, and
    /// SwiftUI mounts its `WindowAccessor` while it renders inside the window's layout pass. A
    /// resize from there is applied to the content view twice. If this starts failing, AppKit has
    /// changed and the reasoning in `TabWindowController.placeInitialFrame(of:pinnedSize:)` should
    /// be measured again.
    @Test("A resize from a WindowAccessor callback leaves the content view out of step with the window")
    func resizingFromALayoutCallbackOvershootsTheContent() {
        let window = TabWindowController.makeEditorWindow()
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let detail = Self.installSplit(in: window)
        window.layoutIfNeeded()
        let initialSize = window.frame.size
        let target = pinnedSize

        detail.rootView = AnyView(Color.clear.background(WindowAccessor { accessed in
            accessed.setFrame(NSRect(origin: accessed.frame.origin, size: target), display: true)
        }))
        window.layoutIfNeeded()

        #expect(window.frame.size == target)
        #expect(window.contentView?.frame.width == target.width + (target.width - initialSize.width))
        #expect(window.contentView?.frame.height == target.height + (target.height - initialSize.height))
    }

    // MARK: - Helpers

    /// No session and a workspace handed in whole, so nothing reaches the connection store. The
    /// window is never shown or closed: closing runs the controller's own teardown, which cancels
    /// connects.
    private func withConnectionWindow(_ body: (NSWindow) throws -> Void) throws {
        let connection = TestFixtures.makeConnection(name: "Pinned frame")
        let workspace = ConnectionWorkspace(
            connectionId: connection.id,
            payload: nil,
            autoConnect: false,
            payloadConnection: connection,
            session: nil,
            sessionState: nil,
            trailingPaneState: nil,
            phase: .connecting
        )
        let controller = TabWindowController(
            payload: EditorTabPayload(connectionId: connection.id),
            pinnedWindowSize: pinnedSize,
            adopting: workspace
        )
        let window = try #require(controller.window)
        defer {
            window.delegate = nil
            window.contentViewController = nil
            workspace.teardown()
        }
        try body(window)
    }

    private static func installSplit(in window: NSWindow) -> NSHostingController<AnyView> {
        let split = NSSplitViewController()
        let sidebar = NSViewController()
        sidebar.view = NSView()
        split.addSplitViewItem(NSSplitViewItem(sidebarWithViewController: sidebar))
        let detail = NSHostingController(rootView: AnyView(Color.clear))
        detail.sizingOptions = []
        split.addSplitViewItem(NSSplitViewItem(viewController: detail))
        window.contentViewController = split
        return detail
    }
}
