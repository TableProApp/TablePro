//
//  QuickSwitcherPanelControllerTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProTestSupport
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

    /// One controller serves Open Quickly and Jump to Column, so a command that toggles its own
    /// panel asks which one is up rather than whether any is.
    @Test("a presented identity answers only for itself and clears on close")
    func presentedIdentityIsTracked() {
        let controller = QuickSwitcherPanelController()
        controller.present(Text(verbatim: "columns"), over: nil, identity: "column-jump")
        #expect(controller.isPresenting("column-jump"))
        #expect(controller.isPresenting("open-quickly") == false)

        controller.present(Text(verbatim: "objects"), over: nil)
        #expect(controller.isPresented)
        #expect(controller.isPresenting("column-jump") == false)

        controller.present(Text(verbatim: "columns"), over: nil, identity: "column-jump")
        controller.dismiss()
        #expect(controller.isPresenting("column-jump") == false)
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
    @Test("Closing Open Quickly releases its view model and the result list it holds")
    func closingReleasesTheViewModel() async throws {
        let controller = QuickSwitcherPanelController()
        weak var released: QuickSwitcherViewModel?
        do {
            let viewModel = QuickSwitcherViewModel(connectionId: UUID())
            released = viewModel
            controller.present(QuickSwitcherPanelContent(viewModel: viewModel) { _, _ in }, over: nil)
            let panel = try #require(controller.presentedWindow as? QuickSwitcherPanel)
            try await waitUntil { panel.keyCommandHandler != nil }
        }

        controller.dismiss()

        try await waitUntil { released == nil }
    }

    @Test("A retained panel comes back as the same window, answering for the model it was given last")
    func retainedPanelSwapsItsModel() async throws {
        let controller = QuickSwitcherPanelController()
        defer { controller.dismiss() }
        weak var released: QuickSwitcherViewModel?
        weak var firstPanel: QuickSwitcherPanel?
        do {
            let viewModel = QuickSwitcherViewModel(connectionId: UUID())
            released = viewModel
            controller.present(
                QuickSwitcherPanelContent(viewModel: viewModel) { _, _ in },
                over: nil,
                identity: "open-quickly",
                retainsPanel: true
            )
            let panel = try #require(controller.presentedWindow as? QuickSwitcherPanel)
            firstPanel = panel
            try await waitUntil { panel.keyCommandHandler != nil }
        }
        controller.dismiss()

        let viewModel = QuickSwitcherViewModel(connectionId: UUID())
        controller.present(
            QuickSwitcherPanelContent(viewModel: viewModel) { _, _ in },
            over: nil,
            identity: "open-quickly",
            retainsPanel: true
        )
        let panel = try #require(controller.presentedWindow as? QuickSwitcherPanel)
        #expect(panel === firstPanel)
        try await waitUntil { panel.keyCommandHandler != nil }
        try await waitUntil { released == nil }

        #expect(panel.performKeyEquivalent(with: try Self.key("2", modifiers: .command, window: panel)))
        #expect(viewModel.scope == QuickSwitcherScope.allCases[1])
    }

    @Test("The panel answers its own commands ahead of the search field and passes the rest on")
    func panelAnswersItsCommands() async throws {
        let controller = QuickSwitcherPanelController()
        defer { controller.dismiss() }
        let viewModel = QuickSwitcherViewModel(connectionId: UUID())
        controller.present(QuickSwitcherPanelContent(viewModel: viewModel) { _, _ in }, over: nil)
        let panel = try #require(controller.presentedWindow as? QuickSwitcherPanel)
        try await waitUntil { panel.keyCommandHandler != nil }
        let handler = try #require(panel.keyCommandHandler)

        #expect(handler(try Self.key("n", modifiers: .control, window: panel)))
        #expect(!handler(try Self.key("a", modifiers: [], window: panel)))

        let scope = QuickSwitcherScope.allCases[1]
        #expect(panel.performKeyEquivalent(with: try Self.key("2", modifiers: .command, window: panel)))
        #expect(viewModel.scope == scope)
    }

    private static func key(_ characters: String, modifiers: NSEvent.ModifierFlags, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        ))
    }
}
