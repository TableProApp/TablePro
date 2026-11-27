import Foundation
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

// A selection change used to copy every selected row into the inspector's edit state while the inspector was hidden.
@MainActor
struct HiddenInspectorEditStateTests {
    private static let columns = ["id", "token", "created_at", "name"]
    private static let columnTypes: [ColumnType] = [
        .integer(rawType: "int4"), .text(rawType: "uuid"), .timestamp(rawType: "timestamptz"), .text(rawType: "text")
    ]

    private let fixture = CoordinatorFixture(connection: TestFixtures.makeConnection(type: .postgresql))
    private let paneState = TrailingPaneState()

    @Test("A selection change with the inspector off screen copies no rows")
    func hiddenInspectorHoldsNoRows() throws {
        try selectFirstRow(of: makeTable())

        makeView().updateSidebarEditState()

        #expect(paneState.inspector.editState.fields.isEmpty)
        #expect(paneState.inspector.editState.allRows.isEmpty)
        #expect(paneState.inspector.editState.rowIDs.isEmpty)
    }

    @Test("Turning the inspector on fills it for the current selection")
    func revealFillsTheSelection() throws {
        try selectFirstRow(of: makeTable())
        let view = makeView()
        view.updateSidebarEditState()

        paneState.inspector.setOnScreen(true)
        view.updateSidebarEditState()

        #expect(paneState.inspector.editState.fields.count == Self.columns.count)
        #expect(paneState.inspector.editState.rowIDs == [.existing(0)])
    }

    @Test("Hiding the inspector drops the rows it held on the next selection change")
    func hidingDropsTheRows() throws {
        try selectFirstRow(of: makeTable())
        let view = makeView()
        paneState.inspector.setOnScreen(true)
        view.updateSidebarEditState()
        try #require(!paneState.inspector.editState.fields.isEmpty)

        paneState.inspector.setOnScreen(false)
        view.updateSidebarEditState()

        #expect(paneState.inspector.editState.fields.isEmpty)
        #expect(paneState.inspector.editState.columns == Self.columns)
    }

    @Test("With the inspector hidden, moving to a query tab clears every handler")
    func hiddenQueryTabClearsHandlers() {
        _ = makeTable()
        let query = QueryTab(title: "Query", query: "SELECT 1", tabType: .query)
        fixture.addTab(query)
        installHandlers()

        makeView().updateSidebarEditState()

        #expect(handlersAreCleared())
        // A value window opened on the table tab keeps writing there.
        #expect(paneState.inspector.editState.detachedStager === fixture.coordinator.rowEditingCoordinator)
    }

    @Test("With the inspector hidden, a result that cannot be edited clears every handler")
    func hiddenReadOnlyResultClearsHandlers() throws {
        try selectFirstRow(of: makeTable(editable: false))
        installHandlers()

        makeView().updateSidebarEditState()

        #expect(handlersAreCleared())
        #expect(paneState.inspector.editState.fields.isEmpty)
    }

    @Test("With the inspector hidden, an editable result still gets its handlers")
    func hiddenEditableResultInstallsHandlers() throws {
        try selectFirstRow(of: makeTable())

        makeView().updateSidebarEditState()

        #expect(paneState.inspector.editState.detachedStager === fixture.coordinator.rowEditingCoordinator)
        #expect(paneState.inspector.editState.onFieldChanged != nil)
    }

    @Test("After the rows go, a value window still stages to its own rows, a typed function as SQL")
    func detachedCommitSurvivesReleasedRows() throws {
        let tabId = makeTable()
        try selectFirstRow(of: tabId)
        let view = makeView()
        paneState.inspector.setOnScreen(true)
        view.updateSidebarEditState()
        let state = paneState.inspector.editState
        let name = try #require(state.holdDetachedField(columnIndex: 3))
        let createdAt = try #require(state.holdDetachedField(columnIndex: 2))

        paneState.inspector.setOnScreen(false)
        view.updateSidebarEditState()
        #expect(state.commitDetachedField("b", to: name))
        #expect(state.commitDetachedField("NOW()", to: createdAt))

        #expect(state.fields.isEmpty && state.allRows.isEmpty)
        let changes = fixture.coordinator.changeManager(forTab: tabId)
        let cells = changes.rowChanges.first { $0.rowID == .existing(0) && $0.type == .update }?.cellChanges ?? []
        #expect(cells.first { $0.columnIndex == 3 }?.newValue == .text("b"))
        #expect(cells.first { $0.columnIndex == 2 }?.newValue == .text("now()"))
        #expect(changes.isExpression(rowID: .existing(0), columnIndex: 2))
    }

    @Test("Released rows report no inspector edits, so a save goes through the staged changes")
    func releasedRowsHoldNoEdits() {
        let state = MultiRowEditState()
        state.configure(
            rowIDs: [.existing(0)],
            allRows: [["1", "x", nil, "a"]],
            columns: Self.columns,
            columnTypes: Self.columnTypes
        )
        state.onFieldChanged = { _, _, _ in }
        state.updateField(at: 3, value: "b")
        #expect(state.hasEdits)

        state.releaseRows()

        #expect(!state.hasEdits)
    }

    // MARK: - Helpers

    private func makeTable(editable: Bool = true) -> UUID {
        var tab = QueryTab(title: "events", query: "SELECT * FROM events", tabType: .table, tableName: "events")
        tab.execution.lastExecutedAt = Date()
        tab.display.resultsViewMode = .data
        tab.tableContext.isEditable = editable
        tab.tableContext.primaryKeyColumns = ["id"]
        fixture.addTab(
            tab,
            rows: TableRows.from(
                queryRows: [
                    [.text("1"), .text("0b1e7c9a-58f4-4b8e-9c55-1f1c86f0a001"), .text("2024-01-01 00:00:00+00"), .text("a")],
                    [.text("2"), .text("0b1e7c9a-58f4-4b8e-9c55-1f1c86f0a002"), .text("2024-01-02 00:00:00+00"), .text("b")]
                ],
                columns: Self.columns,
                columnTypes: Self.columnTypes,
                hasAuthoritativeSchema: true
            )
        )
        fixture.coordinator.changeManager.configureForTable(
            tableName: "events",
            columns: Self.columns,
            primaryKeyColumns: ["id"],
            databaseType: .postgresql,
            generatedColumns: []
        )
        return tab.id
    }

    private func selectFirstRow(of tabId: UUID) throws {
        let model = try #require(fixture.coordinator.activeGridModel)
        model.selectRows([.existing(0)])
        try #require(!model.selection.isEmpty)
    }

    private func makeView() -> MainContentView {
        MainContentView(
            connection: fixture.connection,
            payload: nil,
            windowTitle: .constant(""),
            windowSubtitle: .constant(""),
            windowRepresentedURL: .constant(nil),
            pendingTruncates: .constant([]),
            pendingDeletes: .constant([]),
            tableOperationOptions: .constant([:]),
            trailingPaneState: paneState,
            tabManager: fixture.tabManager,
            toolbarState: fixture.coordinator.toolbarState,
            coordinator: fixture.coordinator
        )
    }

    private func installHandlers() {
        let state = paneState.inspector.editState
        state.onFieldChanged = { _, _, _ in }
        state.onFieldExpressionChanged = { _, _, _ in }
        state.onFieldValuesChanged = { _, _ in }
        state.onFieldReverted = { _, _, _, _ in }
        state.onFieldRemoved = { _, _ in }
    }

    private func handlersAreCleared() -> Bool {
        let state = paneState.inspector.editState
        return state.onFieldChanged == nil
            && state.onFieldExpressionChanged == nil
            && state.onFieldValuesChanged == nil
            && state.onFieldReverted == nil
            && state.onFieldRemoved == nil
    }
}
