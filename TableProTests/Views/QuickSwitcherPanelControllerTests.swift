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
        let panel = QuickSwitcherPanel(
            hostingController: hostingController,
            surfaceCornerRadius: QuickSwitcherMetrics.cornerRadius
        )
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
        let panel = QuickSwitcherPanel(
            hostingController: hostingController,
            surfaceCornerRadius: QuickSwitcherMetrics.cornerRadius
        )
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
        let panel = QuickSwitcherPanel(
            hostingController: NSHostingController(rootView: Text(verbatim: "content")),
            surfaceCornerRadius: QuickSwitcherMetrics.cornerRadius
        )
        #expect(panel.canBecomeKey)
        #expect(panel.canBecomeMain == false)
        panel.close()
    }

    @Test("resigning key closes the panel")
    func resignKeyClosesPanel() {
        let panel = QuickSwitcherPanel(
            hostingController: NSHostingController(rootView: Text(verbatim: "content")),
            surfaceCornerRadius: QuickSwitcherMetrics.cornerRadius
        )
        panel.makeKeyAndOrderFront(nil)
        #expect(panel.isVisible)
        panel.resignKey()
        #expect(panel.isVisible == false)
    }

    @Test("escape closes the panel")
    func escapeClosesPanel() {
        let panel = QuickSwitcherPanel(
            hostingController: NSHostingController(rootView: Text(verbatim: "content")),
            surfaceCornerRadius: QuickSwitcherMetrics.cornerRadius
        )
        panel.makeKeyAndOrderFront(nil)
        #expect(panel.isVisible)
        panel.cancelOperation(nil)
        #expect(panel.isVisible == false)
    }

    @Test("panel uses a nonactivating borderless style mask")
    func panelStyleMask() {
        let panel = QuickSwitcherPanel(
            hostingController: NSHostingController(rootView: Text(verbatim: "content")),
            surfaceCornerRadius: QuickSwitcherMetrics.cornerRadius
        )
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.styleMask.contains(.borderless))
        panel.close()
    }

    /// The radius asserted here is the one the panel was handed, not the metric the panel could
    /// read for itself, so the test fails if the mask ever stops following the shape its content
    /// draws. Asserting it against `QuickSwitcherMetrics.cornerRadius` would pass for any radius,
    /// including one the surface no longer uses.
    @Test("panel masks its content to the surface shape it was given")
    func panelMasksContentToSurfaceShape() throws {
        let surfaceCornerRadius: CGFloat = 19
        let panel = QuickSwitcherPanel(
            hostingController: NSHostingController(rootView: Text(verbatim: "content")),
            surfaceCornerRadius: surfaceCornerRadius
        )
        let contentView = try #require(panel.contentViewController?.view)
        #expect(panel.hasShadow)
        if #available(macOS 26.0, *) {
            let contentLayer = try #require(contentView.layer)
            #expect(contentLayer.cornerRadius == surfaceCornerRadius)
            #expect(contentLayer.cornerCurve == .continuous)
            #expect(contentLayer.masksToBounds)
        } else {
            #expect(contentView.layer?.masksToBounds != true, "the surface clips itself below macOS 26")
        }
        panel.close()
    }
}
