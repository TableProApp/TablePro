//
//  ERDiagramInitialFitTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

@MainActor
private final class HostedDiagram {
    let viewModel: ERDiagramViewModel
    private let window: NSWindow
    private let host: NSHostingView<AnyView>

    init(viewModel: ERDiagramViewModel) {
        self.viewModel = viewModel
        let frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: AnyView(ERDiagramView(viewModel: viewModel)))
        host.sizingOptions = []
        window.contentView = host
        settle()
    }

    var scrollView: DiagramScrollView? {
        host.firstDescendant(of: DiagramScrollView.self)
    }

    func leaveTheTab() {
        host.rootView = AnyView(Color.clear)
        settle()
    }

    func returnToTheTab() {
        host.rootView = AnyView(ERDiagramView(viewModel: viewModel))
        settle()
    }

    func close() {
        window.orderOut(nil)
    }

    private func settle() {
        for _ in 0 ..< 20 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }
}

@MainActor
struct ERDiagramInitialFitTests {
    @Test("A diagram that loaded before its canvas existed opens fitted to the canvas")
    func loadedDiagramOpensFitted() async throws {
        let fixture = ERDiagramLoadFixture()
        defer { fixture.tearDown() }
        await fixture.viewModel.loadDiagram()

        let diagram = HostedDiagram(viewModel: fixture.viewModel)
        defer { diagram.close() }

        let scrollView = try #require(diagram.scrollView)
        let fit = try #require(ERDiagramLoadFixture.exactFit(of: scrollView))
        #expect(fit < 1)
        #expect(abs(scrollView.magnification - fit) < 0.001)
        #expect(diagram.viewModel.viewport.magnification == scrollView.magnification)
    }

    @Test("Coming back to a diagram tab keeps the zoom chosen on it rather than fitting again")
    func returningKeepsTheChosenZoom() async throws {
        let fixture = ERDiagramLoadFixture()
        defer { fixture.tearDown() }
        await fixture.viewModel.loadDiagram()

        let diagram = HostedDiagram(viewModel: fixture.viewModel)
        defer { diagram.close() }
        diagram.viewModel.viewport.resetZoom()
        diagram.viewModel.viewport.zoomOut()
        #expect(diagram.viewModel.viewport.magnification == 0.75)

        diagram.leaveTheTab()
        #expect(diagram.scrollView == nil)
        diagram.returnToTheTab()

        let scrollView = try #require(diagram.scrollView)
        #expect(scrollView.magnification == 0.75)
        #expect(diagram.viewModel.viewport.magnification == 0.75)
    }
}
