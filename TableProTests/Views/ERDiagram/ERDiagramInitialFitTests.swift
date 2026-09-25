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
    private func makeLoadedViewModel() -> ERDiagramViewModel {
        let viewModel = ERDiagramViewModel(connectionId: UUID(), databaseName: "app", schemaKey: "app.default")
        let near = ERTableNode(id: UUID(), tableName: "near", columns: [], displayColumns: [], clusterId: nil)
        let far = ERTableNode(id: UUID(), tableName: "far", columns: [], displayColumns: [], clusterId: nil)
        var graph = viewModel.graph
        graph.nodes = [near, far]
        graph.nodeIndex = [near.tableName: near.id, far.tableName: far.id]
        viewModel.graph = graph
        viewModel.setPositionOverride(nodeId: near.id, position: CGPoint(x: 200, y: 200))
        viewModel.setPositionOverride(nodeId: far.id, position: CGPoint(x: 2_400, y: 1_600))
        viewModel.loadState = .loaded
        viewModel.viewport.fitToWindowOnceLaidOut()
        return viewModel
    }

    @Test("A diagram that loaded before its canvas existed opens fitted to the canvas")
    func loadedDiagramOpensFitted() throws {
        let diagram = HostedDiagram(viewModel: makeLoadedViewModel())
        defer { diagram.close() }

        let scrollView = try #require(diagram.scrollView)
        let content = try #require(scrollView.documentView).bounds.size
        #expect(scrollView.magnification < 1.0)
        #expect(diagram.viewModel.viewport.magnification == scrollView.magnification)
        #expect(scrollView.documentVisibleRect.width >= content.width - 1)
        #expect(scrollView.documentVisibleRect.height >= content.height - 1)
    }

    @Test("Coming back to a diagram tab keeps the zoom chosen on it rather than fitting again")
    func returningKeepsTheChosenZoom() throws {
        let diagram = HostedDiagram(viewModel: makeLoadedViewModel())
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
