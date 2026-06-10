//
//  QuickSwitcherPanelControllerTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

@MainActor
struct QuickSwitcherPanelControllerTests {
    @Test("present shows the panel")
    func presentShowsPanel() {
        let controller = QuickSwitcherPanelController()
        controller.present(Text(verbatim: "content"), over: nil)
        #expect(controller.isPresented)
        controller.dismiss()
    }

    @Test("dismiss hides the panel")
    func dismissHidesPanel() {
        let controller = QuickSwitcherPanelController()
        controller.present(Text(verbatim: "content"), over: nil)
        controller.dismiss()
        #expect(controller.isPresented == false)
    }

    @Test("presenting again replaces the previous panel")
    func presentReplacesPreviousPanel() {
        let controller = QuickSwitcherPanelController()
        controller.present(Text(verbatim: "first"), over: nil)
        controller.present(Text(verbatim: "second"), over: nil)
        #expect(controller.isPresented)
        controller.dismiss()
        #expect(controller.isPresented == false)
    }

    @Test("losing key status dismisses the panel")
    func resignKeyDismissesPanel() {
        let controller = QuickSwitcherPanelController()
        controller.present(Text(verbatim: "content"), over: nil)
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        #expect(controller.isPresented == false)
    }

    @Test("panel cannot become main but can become key")
    func panelKeyAndMainBehavior() {
        let panel = QuickSwitcherPanel(contentView: NSView())
        #expect(panel.canBecomeKey)
        #expect(panel.canBecomeMain == false)
        panel.orderOut(nil)
    }

    @Test("escape on the panel invokes onCancel")
    func escapeInvokesOnCancel() {
        let panel = QuickSwitcherPanel(contentView: NSView())
        var cancelled = false
        panel.onCancel = { cancelled = true }
        panel.cancelOperation(nil)
        #expect(cancelled)
        panel.orderOut(nil)
    }
}
