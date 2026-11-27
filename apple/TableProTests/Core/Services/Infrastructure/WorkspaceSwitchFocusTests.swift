//
//  WorkspaceSwitchFocusTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProTextEngine
import Testing

// Switching connection in a window took the focused editor out of the window and left nobody holding the keyboard:
// every key beeped until a click. The keyboard now stays in the pane it was in.
@MainActor
struct WorkspaceSwitchFocusTests {
    private final class StubDelegate: TextViewDelegate {}

    @MainActor
    private struct Harness {
        let controller: MainSplitViewController
        let first: ConnectionWorkspace
        let second: ConnectionWorkspace
        let window: NSWindow
        private let delegate = StubDelegate()

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

        func addEditor(to workspace: ConnectionWorkspace) -> TextView {
            let editor = TextView(
                string: "SELECT 1",
                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                textColor: .labelColor,
                lineHeightMultiplier: 1.0,
                wrapLines: false,
                isEditable: true,
                isSelectable: true,
                letterSpacing: 1.0,
                delegate: delegate
            )
            editor.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
            workspace.panes.detail.view.addSubview(editor)
            return editor
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

    @Test("Switching connection from the editor puts the keyboard in the incoming connection's editor")
    func editorFocusFollowsTheSwitch() {
        let harness = Harness()
        defer { harness.tearDown() }
        let outgoing = harness.addEditor(to: harness.first)
        let incoming = harness.addEditor(to: harness.second)
        #expect(harness.window.makeFirstResponder(outgoing))

        harness.controller.workspaces.select(harness.second.connectionId)

        #expect(harness.window.firstResponder === incoming)
    }

    @Test("Switching connection from the sidebar leaves the incoming editor alone")
    func sidebarFocusDoesNotJumpToTheEditor() {
        let harness = Harness()
        defer { harness.tearDown() }
        let incoming = harness.addEditor(to: harness.second)
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 160, height: 22))
        harness.first.panes.sidebar.view.addSubview(field)
        #expect(harness.window.makeFirstResponder(field))

        harness.controller.workspaces.select(harness.second.connectionId)

        #expect(harness.window.firstResponder !== incoming)
    }
}
