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

    @Test("dismiss closes the panel and clears the presented state")
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

    /// The real content, not a `Text`. The panel sizes itself once from `sizeThatFits` before it is
    /// ever shown, so content that measures to nothing produces a panel that exists, takes key, and
    /// draws no search field. `Text` cannot catch that, because the thing being measured is the
    /// glass surface, the scope chips and the footer.
    @Test("panel sizes itself from the real content")
    func panelSizesFromRealContent() {
        let viewModel = QuickSwitcherViewModel(connectionId: UUID())
        let hostingController = NSHostingController(
            rootView: QuickSwitcherPanelContent(viewModel: viewModel) { _, _ in }
        )
        let panel = QuickSwitcherPanel(hostingController: hostingController)
        #expect(panel.frame.width >= 600, "the panel keeps its declared width")
        #expect(panel.frame.height > 100, "input row, scope chips and footer all have height")
        #expect(panel.frame.height < 900, "an unbounded height would mean the list grew without limit")
        panel.close()
    }

    @Test("dismiss after the panel already closed is a safe no-op")
    func dismissAfterAlreadyClosedIsNoOp() {
        let controller = QuickSwitcherPanelController()
        controller.present(Text(verbatim: "content"), over: nil)
        controller.dismiss()
        controller.dismiss()
        #expect(controller.isPresented == false)
    }

    @Test("panel can become key but not main")
    func panelKeyAndMainBehavior() {
        let panel = QuickSwitcherPanel(hostingController: NSHostingController(rootView: Text(verbatim: "content")))
        #expect(panel.canBecomeKey)
        #expect(panel.canBecomeMain == false)
        panel.close()
    }

    @Test("resigning key closes the panel")
    func resignKeyClosesPanel() {
        let panel = QuickSwitcherPanel(hostingController: NSHostingController(rootView: Text(verbatim: "content")))
        panel.makeKeyAndOrderFront(nil)
        #expect(panel.isVisible)
        panel.resignKey()
        #expect(panel.isVisible == false)
    }

    @Test("escape closes the panel")
    func escapeClosesPanel() {
        let panel = QuickSwitcherPanel(hostingController: NSHostingController(rootView: Text(verbatim: "content")))
        panel.makeKeyAndOrderFront(nil)
        #expect(panel.isVisible)
        panel.cancelOperation(nil)
        #expect(panel.isVisible == false)
    }

    @Test("panel uses a nonactivating borderless style mask")
    func panelStyleMask() {
        let panel = QuickSwitcherPanel(hostingController: NSHostingController(rootView: Text(verbatim: "content")))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.styleMask.contains(.borderless))
        panel.close()
    }
}
