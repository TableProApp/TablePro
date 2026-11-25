//
//  SwitcherPanelFocusTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

// The choosers cleared the window's first responder before presenting, which only the popover form gives back. With
// no toolbar anchor they float in a panel, and closing it left the window holding no focus: every key beeped and the
// sidebar selection turned grey.
@MainActor
struct SwitcherPanelFocusTests {
    @Test("Opening and closing the connection chooser as a panel keeps the window's focus")
    func panelChooserKeepsFocus() throws {
        let connection = TestFixtures.makeConnection(name: "Chooser focus")
        let workspace = ConnectionWorkspace(
            connectionId: connection.id,
            payload: nil,
            autoConnect: false,
            payloadConnection: connection,
            session: nil,
            sessionState: SessionStateFactory.create(connection: connection, payload: nil),
            trailingPaneState: nil,
            phase: .idle
        )
        let controller = MainSplitViewController(payload: nil, sessionState: nil, adopting: workspace)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        let field = NSTextField(frame: NSRect(x: 400, y: 300, width: 200, height: 22))
        controller.view.addSubview(field)
        defer {
            controller.switcherPresenter.dismiss()
            window.orderOut(nil)
            window.contentViewController = nil
            workspace.teardown()
        }
        try #require(ToolbarSwitcherPresenter.anchor(in: window, MainWindowToolbar.connection, hiddenBy: nil) == nil)
        #expect(window.makeFirstResponder(field))

        controller.openConnectionSwitcher()
        #expect(controller.switcherPresenter.isPresenting)
        controller.switcherPresenter.dismiss()

        #expect(field.currentEditor() != nil)
    }
}
