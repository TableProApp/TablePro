//
//  ERDiagramViewModelLoadTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
struct ERDiagramViewModelLoadTests {
    private func makeCanvas(for viewModel: ERDiagramViewModel) -> DiagramScrollView {
        let scrollView = DiagramScrollView(frame: .zero)
        scrollView.allowsMagnification = true
        scrollView.minMagnification = DiagramZoom.minimum
        scrollView.maxMagnification = DiagramZoom.maximum
        scrollView.documentView = NSView(frame: CGRect(origin: .zero, size: viewModel.cachedCanvasSize))
        viewModel.viewport.attach(to: scrollView)
        scrollView.setFrameSize(CGSize(width: 900, height: 700))
        scrollView.tile()
        return scrollView
    }

    private func hasFailed(_ state: ERDiagramViewModel.LoadState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    @Test("A load started while another is still running waits for it instead of fitting the diagram again")
    func overlappingLoadFitsOnce() async throws {
        let opening = CatalogReadHold()
        let returning = CatalogReadHold()
        let fixture = ERDiagramLoadFixture(holds: [opening, returning])
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel

        let openingLoad = Task { await viewModel.loadDiagram() }
        await opening.reached.wait()
        let returningLoad = Task { await viewModel.loadDiagram() }
        await Task.yield()

        await opening.release.open()
        await openingLoad.value
        let scrollView = makeCanvas(for: viewModel)
        let fit = try #require(ERDiagramLoadFixture.exactFit(of: scrollView))
        #expect(fit < 1)
        #expect(abs(scrollView.magnification - fit) < 0.001)

        viewModel.viewport.resetZoom()
        viewModel.viewport.zoomOut()
        await returning.release.open()
        await returningLoad.value

        #expect(scrollView.magnification == 0.75)
        #expect(fixture.driver.catalogReadCount == 1)
        #expect(viewModel.loadState == .loaded)
    }

    @Test("A load that failed can be tried again")
    func failedLoadCanBeRetried() async {
        let fixture = ERDiagramLoadFixture(failingReads: 1)
        defer { fixture.tearDown() }

        await fixture.viewModel.loadDiagram()
        #expect(hasFailed(fixture.viewModel.loadState))

        await fixture.viewModel.loadDiagram()
        #expect(fixture.viewModel.loadState == .loaded)
        #expect(fixture.driver.catalogReadCount == 2)
    }
}
