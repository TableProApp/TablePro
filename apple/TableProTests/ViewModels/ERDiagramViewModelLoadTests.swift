import AppKit
import Combine
@testable import TablePro
import TableProTestSupport
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

    @Test("A refresh keeps every table where it was and puts a new one beside them")
    func refreshKeepsEveryPosition() async throws {
        let fixture = ERDiagramLoadFixture(tableCount: 3, columnsPerTable: 4)
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel
        await viewModel.loadDiagram()
        let dragged = try #require(viewModel.graph.nodes.first?.id)
        viewModel.setPositionOverride(nodeId: dragged, position: CGPoint(x: 900, y: 700))
        let before = Dictionary(uniqueKeysWithValues: viewModel.graph.nodes.map { ($0.id, viewModel.position(for: $0.id)) })
        let drawn = viewModel.cachedNodeRects.values.reduce(CGRect.null) { $0.union($1) }

        fixture.driver.addTable("table_new", columns: [TestFixtures.makeColumnInfo(name: "id")])
        await viewModel.refresh()

        for (id, position) in before {
            #expect(viewModel.position(for: id) == position)
        }
        let added = try #require(viewModel.graph.nodeIndex["table_new"])
        #expect(viewModel.nodeRect(for: added).minX > drawn.maxX)
        #expect(viewModel.loadState == .loaded)
        #expect(fixture.driver.catalogReadCount == 2)
    }

    @Test("A table asked for on the canvas lands where it was asked for")
    func requestedTableLandsAtThePoint() async throws {
        let fixture = ERDiagramLoadFixture(tableCount: 2, columnsPerTable: 3)
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel
        await viewModel.loadDiagram()
        let point = CGPoint(x: 1_400, y: 900)
        viewModel.pendingPlacement = ERDiagramPendingPlacement(point: point, tableName: "table_new")

        fixture.driver.addTable("table_new", columns: [TestFixtures.makeColumnInfo(name: "id")])
        await viewModel.refresh()

        let added = try #require(viewModel.graph.nodeIndex["table_new"])
        #expect(viewModel.position(for: added) == point)
        #expect(viewModel.pendingPlacement == nil)
    }

    @Test("Create Table's notice names the table the canvas asked for, and the diagram refreshes for it")
    func createdTableNoticeClaimsThePlacement() async throws {
        let fixture = ERDiagramLoadFixture(tableCount: 2, columnsPerTable: 3)
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel
        await viewModel.loadDiagram()
        let point = CGPoint(x: 1_200, y: 800)
        viewModel.pendingPlacement = ERDiagramPendingPlacement(point: point)
        let scope = try #require(viewModel.scope)

        fixture.driver.addTable("table_new", columns: [TestFixtures.makeColumnInfo(name: "id")])
        AppCommands.shared.objectChanged.send(
            DatabaseObjectChange(connectionId: scope.connectionId, scope: scope, name: "table_new", kind: .rows)
        )
        try await waitUntil { viewModel.graph.nodeIndex["table_new"] != nil && !viewModel.isRefreshing }

        let added = try #require(viewModel.graph.nodeIndex["table_new"])
        #expect(viewModel.position(for: added) == point)
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
