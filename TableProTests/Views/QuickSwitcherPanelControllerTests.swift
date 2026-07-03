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

    @Test("panel resolves a non-zero frame from its content before showing")
    func panelResolvesNonZeroFrame() {
        let hostingController = NSHostingController(rootView: Text(verbatim: "content"))
        let panel = QuickSwitcherPanel(hostingController: hostingController)
        #expect(panel.frame.width > 0)
        #expect(panel.frame.height > 0)
        panel.close()
    }

    @Test("closing the panel window clears the presented state")
    func windowWillCloseClearsPresentedState() {
        let controller = QuickSwitcherPanelController()
        controller.present(Text(verbatim: "content"), over: nil)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(controller.isPresented == false)
    }

    @Test("dismiss after the panel already closed is a safe no-op")
    func dismissAfterAlreadyClosedIsNoOp() {
        let controller = QuickSwitcherPanelController()
        controller.present(Text(verbatim: "content"), over: nil)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller.dismiss()
        #expect(controller.isPresented == false)
    }

    @Test("panel can become key and main")
    func panelKeyAndMainBehavior() {
        let panel = QuickSwitcherPanel(hostingController: NSHostingController(rootView: EmptyView()))
        #expect(panel.canBecomeKey)
        #expect(panel.canBecomeMain)
        panel.close()
    }

    @Test("resigning key closes the panel")
    func resignKeyClosesPanel() {
        let panel = QuickSwitcherPanel(hostingController: NSHostingController(rootView: EmptyView()))
        panel.resignKey()
        #expect(panel.isVisible == false)
    }

    @Test("escape closes the panel")
    func escapeClosesPanel() {
        let panel = QuickSwitcherPanel(hostingController: NSHostingController(rootView: EmptyView()))
        panel.cancelOperation(nil)
        #expect(panel.isVisible == false)
    }

    @Test("panel uses a nonactivating borderless style mask")
    func panelStyleMask() {
        let panel = QuickSwitcherPanel(hostingController: NSHostingController(rootView: EmptyView()))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.styleMask.contains(.borderless))
        panel.close()
    }
}
