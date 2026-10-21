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
        // The load is a main-actor task, so a block queued after it runs once it has joined the first.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

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

    @Test("A key into another schema is not drawn to a same-named table of this one")
    func keyIntoAnotherSchemaIsNotDrawn() async {
        let fixture = ERDiagramLoadFixture(
            foreignKeys: [
                "table_1": [ForeignKeyInfo(
                    name: "local_fk", column: "column_1", referencedTable: "table_0",
                    referencedColumn: "column_0", referencedSchema: "main"
                )],
                "table_2": [ForeignKeyInfo(
                    name: "audit_fk", column: "column_1", referencedTable: "table_0",
                    referencedColumn: "column_0", referencedSchema: "audit"
                )]
            ],
            schema: "main"
        )
        defer { fixture.tearDown() }

        await fixture.viewModel.loadDiagram()

        #expect(fixture.viewModel.graph.edges.map { $0.fkName } == ["local_fk"])
        let audited = fixture.viewModel.graph.nodes.first { $0.tableName == "table_2" }
        #expect(audited?.columns.first { $0.name == "column_1" }?.isForeignKey == true)
    }
}
