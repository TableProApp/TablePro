//
//  DataGridMountTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

// A second controller over a model that already has an owner, the way a tab switch remounts its grid.
@MainActor
private final class Remount {
    let controller: DataGridViewController
    let window: GridTestWindow

    init(_ model: DataGridModel, size: NSSize = NSSize(width: 600, height: 300)) {
        controller = DataGridViewController(model: model)
        window = GridTestWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = content
        controller.view.frame = content.bounds
        content.addSubview(controller.view)
        layout()
    }

    func layout() {
        window.contentView?.layoutSubtreeIfNeeded()
        controller.container.layoutSubtreeIfNeeded()
        for pane in controller.panes {
            pane.scrollView.layoutSubtreeIfNeeded()
            pane.tableView.layoutSubtreeIfNeeded()
        }
    }

    func close() {
        controller.dismantle()
        window.orderOut(nil)
    }
}

@MainActor
struct DataGridMountTests {
    private static func rows(_ values: [String]) -> TableRows {
        TableRows.from(
            queryRows: values.map { [PluginCellValue.text($0)] },
            columns: ["name"],
            columnTypes: [.text(rawType: nil)]
        )
    }

    private static func numbered(_ count: Int) -> TableRows {
        rows((0..<count).map { "row \($0)" })
    }

    private func text(atRow row: Int, of model: DataGridModel, through controller: DataGridViewController) throws -> String {
        let rowModel = try #require(model.row(at: row))
        let column = try #require(model.columns.column(at: 0))
        return controller.presenter.displayText(
            of: rowModel,
            dataIndex: column.dataIndex,
            type: column.type,
            formats: model.store.displayFormats,
            databaseType: model.configuration.traits.databaseType,
            columnCount: model.rows.columns.count
        )
    }

    private func scroll(_ table: NSTableView, toRow row: Int, inset: CGFloat) {
        table.scroll(NSPoint(x: 0, y: table.rect(ofRow: row).minY - inset))
    }

    // MARK: - Formatted text across a remount

    @Test("A remount reuses the formatted text the previous mount produced")
    func remountReusesFormattedText() throws {
        let grid = HostedDataGrid(rows: Self.rows(["A"]))
        #expect(try text(atRow: 0, of: grid.model, through: grid.controller) == "A")
        grid.close()
        _ = grid.owner.tableRows.edit(row: 0, column: 0, value: .text("B"))

        let remount = Remount(grid.model)
        defer { remount.close() }

        #expect(try text(atRow: 0, of: grid.model, through: remount.controller) == "A")
        grid.model.reloadRows()
        #expect(try text(atRow: 0, of: grid.model, through: remount.controller) == "B")
    }

    @Test("A remount with a display format applied still reuses the formatted text")
    func remountWithDisplayFormatReusesText() throws {
        let grid = HostedDataGrid(rows: Self.rows(["A"])) { _, model in
            model.store.displayFormats = [.raw]
        }
        #expect(try text(atRow: 0, of: grid.model, through: grid.controller) == "A")
        grid.close()
        _ = grid.owner.tableRows.edit(row: 0, column: 0, value: .text("B"))

        let remount = Remount(grid.model)
        defer { remount.close() }

        #expect(try text(atRow: 0, of: grid.model, through: remount.controller) == "A")
    }

    @Test("Another model over the same rows formats them afresh")
    func separateModelsShareNoText() throws {
        let first = HostedDataGrid(rows: Self.rows(["A"]))
        defer { first.close() }
        #expect(try text(atRow: 0, of: first.model, through: first.controller) == "A")

        let second = HostedDataGrid(rows: Self.rows(["B"]))
        defer { second.close() }

        #expect(try text(atRow: 0, of: second.model, through: second.controller) == "B")
    }

    // MARK: - Viewport across a remount

    @Test("The rows the reader was looking at come back on a remount, and only once")
    func viewportSurvivesARemount() async throws {
        let grid = HostedDataGrid(rows: Self.numbered(1_000))
        scroll(grid.main, toRow: 500, inset: grid.controller.headerInset)
        try #require(grid.controller.viewportSample()?.row == 500)
        grid.close()

        let anchor = try #require(grid.model.store.viewportAnchor)
        #expect(anchor.firstVisibleRow == .existing(500))

        let remount = Remount(grid.model)
        defer { remount.close() }
        try await waitUntil {
            remount.layout()
            return remount.controller.viewportSample()?.row == 500
        }
        #expect(grid.model.store.viewportAnchor == nil)
    }

    // MARK: - Teardown

    @Test("Unmounting detaches the grid, so later changes leave its tables alone")
    func unmountDetachesTheModel() {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        #expect(grid.model.isMounted)

        grid.close()
        grid.owner.tableRows = Self.numbered(2)
        grid.model.reloadRows()

        #expect(!grid.model.isMounted)
        #expect(grid.main.numberOfRows == 5)
    }

    @Test("Unmounting takes the scroll observers off, so the panes stop moving in step")
    func unmountStopsScrollSync() async throws {
        let grid = HostedDataGrid(rows: Self.numbered(300))
        let mainClip = grid.mainScrollView.contentView
        let frozenClip = grid.frozenScrollView.contentView
        mainClip.setBoundsOrigin(NSPoint(x: 0, y: 400))
        try await waitUntil { frozenClip.bounds.origin.y == 400 }

        grid.close()
        mainClip.setBoundsOrigin(NSPoint(x: 0, y: 900))

        #expect(mainClip.bounds.origin.y != frozenClip.bounds.origin.y)
    }

    @Test("A newer mount of the same model survives the older mount going")
    func newerMountSurvivesOlderTeardown() {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        let newer = Remount(grid.model)
        #expect(grid.model.mountedView === newer.controller)

        grid.close()

        #expect(grid.model.mountedView === newer.controller)
        #expect(grid.model.store.viewportAnchor == nil)

        newer.close()
        #expect(!grid.model.isMounted)
    }

    @Test("Unmounting twice is harmless")
    func unmountIsIdempotent() {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)

        grid.close()
        grid.controller.dismantle()

        #expect(!grid.model.isMounted)
    }

    @Test("A grid handed another model moves to it instead of rebuilding")
    func adoptMovesToTheNewModel() {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        let otherOwner = GridTestOwner(Self.numbered(2))
        let other = DataGridModel()
        other.dataSource = otherOwner
        other.actions = otherOwner
        other.reloadRows()

        grid.controller.adopt(other)

        #expect(!grid.model.isMounted)
        #expect(other.mountedView === grid.controller)
        #expect(grid.main.numberOfRows == 2)
        #expect(grid.frozen.numberOfRows == 2)
        #expect(grid.tableColumn(named: "id") == nil)
        #expect(grid.tableColumn(named: "name") != nil)
    }

    @Test("Taking the grid view out of SwiftUI unmounts it from its model")
    func swiftUIRemovalUnmounts() async throws {
        let owner = GridTestOwner(GridFixtureRows.people)
        let model = DataGridModel()
        model.dataSource = owner
        model.actions = owner
        model.reloadRows()
        let host = NSHostingView(rootView: AnyView(DataGridView(model: model)))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let window = GridTestWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.orderOut(nil) }

        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return model.isMounted
        }

        host.rootView = AnyView(Color.clear)

        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return !model.isMounted
        }
    }
}
