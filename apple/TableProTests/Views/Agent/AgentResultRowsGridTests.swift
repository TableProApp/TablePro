//
//  AgentResultRowsGridTests.swift
//  TableProTests
//
//  The rows an agent session read are held in full, so the pane's grid sorts them itself.
//

import AppKit
import Combine
import SwiftUI
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
private final class AgentRunList: ObservableObject {
    @Published var runs: [AgentQueryRun]

    init(_ runs: [AgentQueryRun]) {
        self.runs = runs
    }
}

private struct AgentRunsHarness: View {
    @ObservedObject var list: AgentRunList
    let artifacts: AgentArtifactCache

    var body: some View {
        AgentResultRowsView(runs: list.runs, artifacts: artifacts, connection: nil)
    }
}

@MainActor
struct AgentResultRowsGridTests {
    private func run(_ id: String, names: [String]) -> AgentQueryRun {
        let rows = names.map { "[\"\($0)\"]" }.joined(separator: ",")
        return AgentQueryRun(id: id, sql: "select name from users", resultJSON: #"{"columns":["name"],"rows":["# + rows + "]}")
    }

    private func host(_ list: AgentRunList) async -> NSWindow {
        let window = ThemeTestFixture.host(
            AgentRunsHarness(list: list, artifacts: AgentArtifactCache()),
            size: NSSize(width: 600, height: 300)
        )
        await settle(window)
        return window
    }

    // SwiftUI applies a change on a later run-loop turn, so each pass lays out and waits one main-queue turn.
    private func settle(_ window: NSWindow) async {
        for _ in 0 ..< 10 {
            window.contentView?.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func gridModel(in window: NSWindow) throws -> DataGridModel {
        let table = try #require(Self.mainTable(in: window.contentView))
        return try #require(table.controller?.model)
    }

    private func names(_ model: DataGridModel) -> [String] {
        (0..<model.rowCount).compactMap { model.row(at: $0)?.values.first?.asText }
    }

    private static func mainTable(in view: NSView?) -> DataGridTableView? {
        guard let view else { return nil }
        if let table = view as? DataGridTableView, table.paneKind == .main { return table }
        return view.subviews.lazy.compactMap { mainTable(in: $0) }.first
    }

    @Test("A header sort orders the run's rows, and the selection stays on the same row")
    func headerSortOrdersTheHeldRows() async throws {
        let list = AgentRunList([run("1", names: ["carol", "alice", "bob"])])
        let window = await host(list)
        defer { window.contentView = nil }
        let model = try gridModel(in: window)
        try #require(names(model) == ["carol", "alice", "bob"])
        let carol = try #require(model.rowID(at: 0))
        model.selectRows([carol])

        model.setSort(SortState(columns: [SortColumn(columnIndex: 0, direction: .ascending)], source: .user))

        #expect(names(model) == ["alice", "bob", "carol"])
        #expect(model.selectedRowIDs == [carol])
        #expect(model.displayIndex(of: carol) == 2)
        #expect(model.store.layoutScope == .ephemeral)
    }

    @Test("Another run starts with no selection and no sort")
    func anotherRunStartsOver() async throws {
        let first = run("1", names: ["carol", "alice"])
        let list = AgentRunList([first])
        let window = await host(list)
        defer { window.contentView = nil }
        let model = try gridModel(in: window)
        model.setSort(SortState(columns: [SortColumn(columnIndex: 0, direction: .ascending)], source: .user))
        let selected = try #require(model.rowID(at: 0))
        model.selectRows([selected])

        list.runs = [first, run("2", names: ["zed", "amy"])]
        try await waitUntil(timeout: .seconds(5)) {
            window.contentView?.layoutSubtreeIfNeeded()
            return names(model) == ["zed", "amy"]
        }

        #expect(names(model) == ["zed", "amy"])
        #expect(model.selection.isEmpty)
        #expect(!model.store.sortState.isSorting)
    }
}
