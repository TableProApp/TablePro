//
//  DataGridSelectionSummaryMenuTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class SummaryMenuClipboard: ClipboardProvider {
    var text: String?

    func readText() -> String? { text }
    func readGridRows() -> GridRowsClipboardPayload? { nil }
    func writeText(_ text: String) { self.text = text }
    func writeCsv(_ csv: String) { text = csv }
    func writeImage(_ image: NSImage) {}
    func writeRows(tsv: String, html: String?, gridRows: GridRowsClipboardPayload) { text = tsv }
    var hasText: Bool { text != nil }
    var hasGridRows: Bool { false }
}

@MainActor
private final class SummaryMenuLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@Suite("Selection summary menus", .serialized)
@MainActor
struct DataGridSelectionSummaryMenuTests {
    private static let columnTypes: [ColumnType] = [.integer(rawType: "INT"), .text(rawType: "TEXT")]
    private static let selectColumnAction = #selector(TableViewCoordinator.selectColumnFromHeaderMenu(_:))
    private static let copyFigureAction = NSSelectorFromString("copySelectionSummaryFigure:")

    /// The coordinator holds its table view weakly, so the test keeps it alive across an await.
    private struct Fixture {
        let coordinator: TableViewCoordinator
        let tableView: KeyHandlingTableView
    }

    private func makeFixture() -> Fixture {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: false,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: SummaryMenuLayoutPersister()
        )
        let tableRows = TableRows.from(
            queryRows: [
                [.text("1"), .text("a")],
                [.text("2"), .text("b")],
                [.text("3"), .text("c")],
            ],
            columns: ["amount", "name"],
            columnTypes: Self.columnTypes
        )
        coordinator.tableRowsProvider = { tableRows }
        coordinator.rebuildColumnMetadataCache(from: tableRows)
        coordinator.updateCache()

        let tableView = KeyHandlingTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        tableView.coordinator = coordinator
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.addTableColumn(DataGridView.makeRowNumberColumn())
        coordinator.tableView = tableView
        coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: coordinator.identitySchema,
            columnTypes: Self.columnTypes,
            savedLayout: nil,
            isEditable: false,
            hiddenColumnNames: [],
            firstClickSortDirection: .ascending,
            widthCalculator: { _, _ in 90 }
        )
        return Fixture(coordinator: coordinator, tableView: tableView)
    }

    private func headerMenu(_ coordinator: TableViewCoordinator, dataColumn: Int) throws -> NSMenu {
        let tableView = try #require(coordinator.tableView)
        let column = try #require(tableView.tableColumns.firstIndex {
            coordinator.dataColumnIndex(from: $0.identifier) == dataColumn
        })
        let menu = NSMenu()
        coordinator.populateHeaderMenu(menu, forColumnAt: column)
        return menu
    }

    private func summarizeColumn(_ dataColumn: Int, in coordinator: TableViewCoordinator) async {
        let tracker = coordinator.selectionSummaryTracker
        tracker.attach(SelectionSummaryState())
        coordinator.selectColumn(dataColumn)
        tracker.selectionDidChange()
        await tracker.pendingTask?.value
    }

    private func makeRowView(_ coordinator: TableViewCoordinator) -> DataGridRowView {
        let rowView = DataGridRowView()
        rowView.coordinator = coordinator
        rowView.rowIndex = 0
        return rowView
    }

    @Test("The header menu offers Select Column just before Copy Column Name")
    func selectColumnPrecedesCopyColumnName() throws {
        let fixture = makeFixture()
        let coordinator = fixture.coordinator
        let items = try headerMenu(coordinator, dataColumn: 1).items

        let select = try #require(items.firstIndex { $0.action == Self.selectColumnAction })
        let next = items.dropFirst(select + 1).first
        #expect(next?.action == #selector(TableViewCoordinator.copyColumnName(_:)))
    }

    @Test("Select Column selects every row of the column the menu was opened on")
    func selectColumnSelectsTheWholeColumn() throws {
        let fixture = makeFixture()
        let coordinator = fixture.coordinator
        let menu = try headerMenu(coordinator, dataColumn: 1)
        let index = try #require(menu.items.firstIndex { $0.action == Self.selectColumnAction })

        menu.performActionForItem(at: index)

        let position = try #require(coordinator.displayPosition(ofDataColumnIndex: 1))
        let selection = coordinator.selectionController.selection
        #expect(selection.columns == IndexSet(integer: position))
        #expect(selection.affectedRows == IndexSet(integersIn: 0..<3))
    }

    @Test("The cell menu offers Copy Sum and Copy Average right after Copy as, as plain text")
    func cellMenuCopiesTheSummary() async throws {
        let fixture = makeFixture()
        let coordinator = fixture.coordinator
        await summarizeColumn(0, in: coordinator)
        #expect(coordinator.selectionSummaryTracker.currentSummary?.numbers != nil)

        let rowView = makeRowView(coordinator)
        let menu = try #require(rowView.contextMenu(target: .cell(dataColumn: 0)))
        let titles = menu.items.map(\.title)
        let copyAs = try #require(titles.firstIndex(of: String(localized: "Copy as")))
        #expect(Array(titles.dropFirst(copyAs + 1).prefix(2)) == [
            String(localized: "Copy Sum"),
            String(localized: "Copy Average"),
        ])

        let clipboard = SummaryMenuClipboard()
        ClipboardService.shared = clipboard
        defer { ClipboardService.shared = NSPasteboardClipboardProvider() }
        menu.performActionForItem(at: copyAs + 1)
        #expect(clipboard.text == "6")
        menu.performActionForItem(at: copyAs + 2)
        #expect(clipboard.text == "2")
        withExtendedLifetime(fixture) {}
    }

    @Test("A selection holding no numbers offers no summary copies")
    func cellMenuHidesSummaryCopiesWithoutNumbers() async throws {
        let fixture = makeFixture()
        let coordinator = fixture.coordinator
        await summarizeColumn(1, in: coordinator)
        let summary = try #require(coordinator.selectionSummaryTracker.currentSummary)
        #expect(summary.numbers == nil)

        let rowView = makeRowView(coordinator)
        let menu = try #require(rowView.contextMenu(target: .cell(dataColumn: 1)))
        #expect(!menu.items.contains { $0.action == Self.copyFigureAction })
        withExtendedLifetime(fixture) {}
    }
}
