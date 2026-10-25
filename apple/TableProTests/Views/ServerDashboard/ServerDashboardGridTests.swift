//
//  ServerDashboardGridTests.swift
//  TableProTests
//
//  Sessions and slow queries are server records, so they draw in the data grid and take its theme,
//  where they were a SwiftUI Table and a plain List that kept the system background under any theme.
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import Testing

@MainActor
struct ServerDashboardGridTests {
    private let sessions = [
        DashboardSession(id: "10", user: "app", database: "shop", state: "active", durationSeconds: 5, duration: "5s", query: "SELECT 1"),
        DashboardSession(id: "2", user: "admin", database: "shop", state: "idle", durationSeconds: 90, duration: "1m 30s", query: ""),
        DashboardSession(id: "7", user: "app", database: "logs", state: "active", durationSeconds: 5, duration: "5s", query: "SELECT 2"),
    ]

    private func ids(_ list: [DashboardSession]) -> [String] {
        list.map(\.id)
    }

    private func sort(_ column: Int, _ direction: SortDirection) -> SortState {
        SortState(columns: [SortColumn(columnIndex: column, direction: direction)], source: .user)
    }

    private func gridTable(in view: NSView?) -> DataGridTableView? {
        guard let view else { return nil }
        if let table = view as? DataGridTableView, table.paneKind == .main { return table }
        for subview in view.subviews {
            if let found = gridTable(in: subview) { return found }
        }
        return nil
    }

    // The list loads its rows in onAppear, which SwiftUI runs on a later turn than the first layout.
    private func host(_ view: some View) async -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.frame(width: 800, height: 400))
        for _ in 0 ..< 10 {
            window.contentView?.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        return window
    }

    @Test("Sessions open longest first, with ties kept in the order the server listed them")
    func sessionsOpenLongestFirst() {
        let sorted = SessionGridColumns.sorted(sessions, by: SessionGridColumns.defaultSort)
        #expect(ids(sorted) == ["2", "10", "7"])
    }

    @Test("A header sort orders by that column, PID in numeric order")
    func sessionsSortByColumn() {
        #expect(ids(SessionGridColumns.sorted(sessions, by: sort(0, .ascending))) == ["2", "7", "10"])
        #expect(ids(SessionGridColumns.sorted(sessions, by: sort(1, .descending))) == ["10", "7", "2"])
        #expect(ids(SessionGridColumns.sorted(sessions, by: sort(SessionGridColumns.durationColumn, .ascending))) == ["10", "7", "2"])
    }

    @Test("Don't Sort shows the sessions in the order the server listed them")
    func clearedSortKeepsArrivalOrder() {
        #expect(ids(SessionGridColumns.sorted(sessions, by: SortState(columns: [], source: .user))) == ["10", "2", "7"])
    }

    @Test("A session row draws every column the table had, in order")
    func sessionRowValues() {
        let row = SessionGridColumns.row(for: sessions[1])
        #expect(row.id == "2")
        #expect(row.values == ["2", "admin", "shop", "idle", "1m 30s", ""])
        #expect(row.values.count == SessionGridColumns.titles.count)
    }

    @Test("The State column keeps the system status hue each session state has always had")
    func stateTones() {
        #expect(SessionGridColumns.stateTone("active") == .positive)
        #expect(SessionGridColumns.stateTone("Running") == .positive)
        #expect(SessionGridColumns.stateTone("idle") == .secondary)
        #expect(SessionGridColumns.stateTone("idle in transaction") == .caution)
        #expect(SessionGridColumns.stateTone("waiting") == .critical)
        #expect(SessionGridColumns.stateTone("LOCKED") == .critical)
        #expect(SessionGridColumns.stateTone("executing") == nil)
        #expect(SessionGridColumns.stateTone("") == nil)
    }

    @Test("A session row tones only its State cell")
    func sessionRowTonesItsState() {
        #expect(SessionGridColumns.row(for: sessions[0]).tones == [SessionGridColumns.stateColumn: .positive])
        #expect(SessionGridColumns.row(for: sessions[1]).tones == [SessionGridColumns.stateColumn: .secondary])
        let unknown = DashboardSession(
            id: "3", user: "app", database: "shop", state: "executing", durationSeconds: 1, duration: "1s", query: ""
        )
        #expect(SessionGridColumns.row(for: unknown).tones.isEmpty)
    }

    @Test("A slow query's duration keeps its orange")
    func slowQueryDurationTone() {
        let rows = SlowQueryGridRows.rows(for: [
            DashboardSlowQuery(duration: "4s", query: "SELECT SLEEP(4)", user: "app", database: "shop"),
        ])
        #expect(rows.first?.tones == [SlowQueryGridRows.durationColumn: .caution])
    }

    @Test("The sessions grid draws the State hue, white on an emphasized selection, and every other cell in the grid text")
    func sessionsGridDrawsTheStateHue() async throws {
        let viewModel = ServerDashboardViewModel(connectionId: UUID(), databaseType: .postgresql, services: .live)
        viewModel.sessions = sessions
        let window = await host(SessionsTableView(viewModel: viewModel))
        defer {
            viewModel.stopAutoRefresh()
            window.contentView = nil
        }
        let table = try #require(gridTable(in: window.contentView))
        let controller = try #require(table.controller)
        let presenter = controller.presenter
        let pass = try #require(presenter.makePass(in: table.effectiveAppearance))
        let palette = pass.palette
        let state = SessionGridColumns.stateColumn
        func textColor(row: Int, column: Int, selected: Bool = false) -> NSColor? {
            let model = controller.model
            guard let rowModel = model.row(at: row),
                  let gridColumn = model.columns.columns.first(where: { $0.dataIndex == column }) else { return nil }
            return presenter.appearance(
                of: rowModel,
                displayRow: row,
                column: gridColumn,
                visualState: presenter.visualState(of: rowModel),
                pass: pass,
                onEmphasizedSelection: selected
            )?.textColor
        }

        // Longest first: the idle session, then the two active ones.
        #expect(textColor(row: 0, column: state) == .secondaryLabelColor)
        #expect(textColor(row: 1, column: state) == .systemGreen)
        #expect(textColor(row: 1, column: state, selected: true) == palette.selectionText)
        #expect(textColor(row: 1, column: 0) == palette.text)
        #expect(textColor(row: 1, column: SessionGridColumns.durationColumn) == palette.text)
    }

    private func headerRedPixels(selecting ids: Set<String>) async throws -> Int {
        let viewModel = ServerDashboardViewModel(connectionId: UUID(), databaseType: .postgresql, services: .live)
        viewModel.sessions = sessions
        viewModel.sessionSelection.ids = ids
        let size = NSSize(width: 800, height: 400)
        let host = NSHostingView(rootView: SessionsTableView(viewModel: viewModel).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer {
            viewModel.stopAutoRefresh()
            window.contentView = nil
        }
        for _ in 0 ..< 10 {
            host.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let headerRows = Int(36 * CGFloat(bitmap.pixelsHigh) / size.height)
        return ThemeTestFixture.count(in: bitmap, rows: 0 ..< headerRows) { color in
            color.alphaComponent > 0.5 && color.redComponent > 0.75 && color.greenComponent < 0.45 && color.blueComponent < 0.45
        }
    }

    @Test("Terminate draws its red glyph while it can end the selected session, and the standard glyph while disabled")
    func terminateGlyphIsRedOnlyWhileEnabled() async throws {
        #expect(try await headerRedPixels(selecting: ["10"]) > 0)
        #expect(try await headerRedPixels(selecting: []) == 0)
    }

    @Test("Cancel and Terminate act on exactly one selected session that is still listed")
    func actionTargetIsOneListedSession() {
        #expect(SessionGridColumns.actionTarget(["7"], in: sessions)?.id == "7")
        #expect(SessionGridColumns.actionTarget(["7", "2"], in: sessions) == nil)
        #expect(SessionGridColumns.actionTarget([], in: sessions) == nil)
        #expect(SessionGridColumns.actionTarget(["99"], in: sessions) == nil)
    }

    @Test("A running slow query keeps its row while its duration grows, and a repeat gets its own")
    func slowQueryRowIdentity() {
        let first = [
            DashboardSlowQuery(duration: "4s", query: "SELECT SLEEP(9)", user: "app", database: "shop"),
            DashboardSlowQuery(duration: "3s", query: "SELECT SLEEP(9)", user: "app", database: "shop"),
        ]
        let later = [
            DashboardSlowQuery(duration: "9s", query: "SELECT SLEEP(9)", user: "app", database: "shop"),
            DashboardSlowQuery(duration: "8s", query: "SELECT SLEEP(9)", user: "app", database: "shop"),
        ]
        let before = SlowQueryGridRows.rows(for: first)
        let after = SlowQueryGridRows.rows(for: later)
        #expect(before.map(\.id) == after.map(\.id))
        #expect(Set(before.map(\.id)).count == 2)
        #expect(after[0].values == ["9s", "SELECT SLEEP(9)", "app", "shop"])
        #expect(after[0].values.count == SlowQueryGridRows.titles.count)
    }

    @Test("The sessions pane draws its records in the data grid")
    func sessionsMountTheDataGrid() async throws {
        let viewModel = ServerDashboardViewModel(connectionId: UUID(), databaseType: .mysql, services: .live)
        viewModel.sessions = sessions
        let window = await host(SessionsTableView(viewModel: viewModel))
        defer {
            viewModel.stopAutoRefresh()
            window.contentView = nil
        }
        let table = try #require(gridTable(in: window.contentView))
        #expect(table.numberOfRows == sessions.count)
    }

    @Test("A session selected in the grid becomes the one Cancel and Terminate act on")
    func gridSelectionReachesTheActionTarget() async throws {
        let viewModel = ServerDashboardViewModel(connectionId: UUID(), databaseType: .postgresql, services: .live)
        viewModel.sessions = sessions
        let window = await host(SessionsTableView(viewModel: viewModel))
        defer {
            viewModel.stopAutoRefresh()
            window.contentView = nil
        }
        let table = try #require(gridTable(in: window.contentView))

        // Longest first: the idle session "2", then "10" and "7".
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

        #expect(viewModel.sessionSelection.ids == ["10"])
        #expect(SessionGridColumns.actionTarget(viewModel.sessionSelection.ids, in: viewModel.sessions)?.id == "10")
    }

    @Test("The slow query pane draws its records in the data grid")
    func slowQueriesMountTheDataGrid() async throws {
        let queries = [DashboardSlowQuery(duration: "4s", query: "SELECT SLEEP(4)", user: "app", database: "shop")]
        let window = await host(SlowQueryListView(queries: queries, error: nil, databaseType: .mysql))
        defer { window.contentView = nil }
        let table = try #require(gridTable(in: window.contentView))
        #expect(table.numberOfRows == 1)
    }
}
