//
//  InspectorExpressionStagingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct InspectorExpressionStagingTests {
    private static let columns = ["id", "token", "created_at", "name"]
    private static let columnTypes: [ColumnType] = [
        .integer(rawType: "int4"), .text(rawType: "uuid"), .timestamp(rawType: "timestamptz"), .text(rawType: "text")
    ]

    private let fixture = CoordinatorFixture(connection: TestFixtures.makeConnection(type: .postgresql))

    private var coordinator: MainContentCoordinator { fixture.coordinator }
    private var changeManager: DataChangeManager { fixture.coordinator.changeManager }

    private func makeTable() -> UUID {
        var tab = QueryTab(title: "events", query: "SELECT * FROM events", tabType: .table, tableName: "events")
        tab.execution.lastExecutedAt = Date()
        tab.display.resultsViewMode = .data
        fixture.addTab(
            tab,
            rows: TableRows.from(
                queryRows: [
                    [.text("1"), .text("0b1e7c9a-58f4-4b8e-9c55-1f1c86f0a001"), .text("2024-01-01 00:00:00+00"), .text("a")],
                    [.text("2"), .text("0b1e7c9a-58f4-4b8e-9c55-1f1c86f0a002"), .text("2024-01-02 00:00:00+00"), .text("b")],
                    [.text("3"), .text("0b1e7c9a-58f4-4b8e-9c55-1f1c86f0a003"), .text("2024-01-03 00:00:00+00"), .text("c")]
                ],
                columns: Self.columns,
                columnTypes: Self.columnTypes,
                hasAuthoritativeSchema: true
            )
        )
        changeManager.configureForTable(
            tableName: "events",
            columns: Self.columns,
            primaryKeyColumns: ["id"],
            databaseType: .postgresql,
            generatedColumns: []
        )
        return tab.id
    }

    private func value(_ tabId: UUID, row: Int, column: Int) -> PluginCellValue {
        coordinator.tabSessionRegistry.tableRows(for: tabId).rows[row].values[column]
    }

    // Wired the way `MainContentView.updateSidebarEditState` wires the inspector.
    private func configuredEditState(_ tabId: UUID, rows rowIDs: [RowID]) -> MultiRowEditState {
        let tableRows = coordinator.tabSessionRegistry.tableRows(for: tabId)
        let selected = rowIDs.compactMap { tableRows.row(withID: $0) }
        let state = MultiRowEditState()
        state.configure(
            rowIDs: selected.map(\.id),
            allRows: selected.map { $0.values.map(\.asText) },
            expressionCells: selected.map { changeManager.expressionColumns(forRow: $0.id) },
            columns: tableRows.columns,
            columnTypes: Self.columnTypes,
            externallyModifiedColumns: Set(selected.flatMap { changeManager.getModifiedColumnsForRow($0.id) }),
            databaseType: .postgresql,
            cellWriter: changeManager.cellWriterSupport
        )
        let rowEditing: RowEditingCoordinator = coordinator.rowEditingCoordinator
        state.onFieldChanged = { [rowEditing] columnIndex, value, continuity in
            rowEditing.stageInspectorFieldEdit(
                columnIndex: columnIndex, value: value, rowIDs: rowIDs, continuity: continuity
            )
        }
        state.onFieldExpressionChanged = { [rowEditing] columnIndex, sql, continuity in
            rowEditing.stageInspectorFieldEdit(
                columnIndex: columnIndex, value: .text(sql), rowIDs: rowIDs, continuity: continuity, isExpression: true
            )
        }
        state.onFieldValuesChanged = { [rowEditing] columnIndex, valuesByRow in
            rowEditing.stageInspectorFieldValues(columnIndex: columnIndex, valuesByRow: valuesByRow)
        }
        state.onFieldReverted = { [rowEditing] columnIndex, valuesByRow, absentRowIDs, expressionRowIDs in
            rowEditing.revertInspectorFieldEdit(
                columnIndex: columnIndex,
                valuesByRow: valuesByRow,
                absentRowIDs: absentRowIDs,
                expressionRowIDs: expressionRowIDs
            )
        }
        return state
    }

    @Test("A function picked in the inspector is pending as SQL and saved unquoted")
    func pickedFunctionIsStagedAsSQL() throws {
        let tabId = makeTable()
        let state = configuredEditState(tabId, rows: [.existing(0)])

        state.setValue(.expression(CellExpression("now()", kinds: [.timestamp, .datetime])), at: 2)

        #expect(changeManager.isExpression(rowID: .existing(0), columnIndex: 2))
        #expect(value(tabId, row: 0, column: 2) == .text("now()"))
        let statement = try #require(try changeManager.generateSQL().first)
        #expect(statement.sql.contains("now()"))
        #expect(!statement.parameters.contains { ($0 as? String) == "now()" })
    }

    @Test("A function name typed into the field is staged as the vocabulary's SQL")
    func typedFunctionIsStagedAsSQL() {
        let tabId = makeTable()
        let state = configuredEditState(tabId, rows: [.existing(0)])

        state.updateField(at: 2, value: "NOW()")

        #expect(changeManager.isExpression(rowID: .existing(0), columnIndex: 2))
        #expect(value(tabId, row: 0, column: 2) == .text("now()"))
    }

    @Test("The same text staged as a literal over the SQL is a change of its own")
    func literalOverExpressionIsAChange() {
        let tabId = makeTable()
        let rowEditing: RowEditingCoordinator = coordinator.rowEditingCoordinator

        rowEditing.stageInspectorFieldEdit(
            columnIndex: 3, value: .text("now()"), rowIDs: [.existing(0)], continuity: .discrete, isExpression: true
        )
        rowEditing.stageInspectorFieldEdit(
            columnIndex: 3, value: .text("now()"), rowIDs: [.existing(0)], continuity: .discrete
        )

        #expect(!changeManager.isExpression(rowID: .existing(0), columnIndex: 3))
        #expect(changeManager.hasChanges)
        #expect(value(tabId, row: 0, column: 3) == .text("now()"))
    }

    // Clearing the field after typing over a staged `now()` used to re-stage the text as the literal `'now()'`.
    @Test("Clearing an inspector edit over SQL the grid staged puts the SQL back")
    func revertRestoresTheExpression() {
        let tabId = makeTable()
        let rows: [RowID] = [.existing(0), .existing(1)]
        coordinator.rowEditingCoordinator.stageInspectorFieldEdit(
            columnIndex: 2, value: .text("now()"), rowIDs: rows, continuity: .discrete, isExpression: true
        )
        let state = configuredEditState(tabId, rows: rows)
        #expect(state.fields[2].isPendingExpression)

        state.updateField(at: 2, value: "2024-05-05 00:00:00+00")
        #expect(!changeManager.isExpression(rowID: .existing(0), columnIndex: 2))

        state.updateField(at: 2, value: "now()")

        #expect(changeManager.isExpression(rowID: .existing(0), columnIndex: 2))
        #expect(changeManager.isExpression(rowID: .existing(1), columnIndex: 2))
        #expect(value(tabId, row: 0, column: 2) == .text("now()"))
        #expect(value(tabId, row: 1, column: 2) == .text("now()"))
    }

    @Test("Generate UUID across the selected rows gives each row its own")
    func generateUUIDAcrossRows() {
        let tabId = makeTable()
        let rows: [RowID] = [.existing(0), .existing(1), .existing(2)]
        let state = configuredEditState(tabId, rows: rows)
        let before = (0..<3).map { value(tabId, row: $0, column: 1) }

        state.setValue(.uuid(.v4), at: 1)

        let after = (0..<3).map { value(tabId, row: $0, column: 1) }
        #expect(Set(after).count == 3)
        #expect(Set(after).isDisjoint(with: before))
        #expect(after.allSatisfy { $0.asText.flatMap(UUID.init(uuidString:)) != nil })
        #expect(FieldValueState.resolve(state.fields[1]) == .multipleValues)

        let reconfigured = configuredEditState(tabId, rows: rows)
        #expect(FieldValueState.resolve(reconfigured.fields[1]) == .multipleValues)
    }

    @Test("Typing into the field after a per-row generate writes that value to every row")
    func typingAfterGenerateOverwritesEveryRow() {
        let tabId = makeTable()
        let rows: [RowID] = [.existing(0), .existing(1)]
        let state = configuredEditState(tabId, rows: rows)
        let typed = "6f1c2a7e-0d3b-4c5f-9a8e-1b2c3d4e5f60"

        state.setValue(.uuid(.v7), at: 1)
        state.updateField(at: 1, value: typed)

        #expect(value(tabId, row: 0, column: 1) == .text(typed))
        #expect(value(tabId, row: 1, column: 1) == .text(typed))
    }

    // MARK: - Inspector-only save

    @Test("An inspector-only save writes a picked function unquoted")
    func sidebarSaveWritesPickedFunction() throws {
        let tabId = makeTable()
        coordinator.gridModel(forTab: tabId).selectRows([.existing(0)])

        let statements = try coordinator.sidebarEditStatements(editedFields: [
            InspectorFieldEdit(columnIndex: 2, columnName: "created_at", newValue: "now()", isExpression: true)
        ])

        let statement = try #require(statements.first)
        #expect(statement.sql.contains("now()"))
        #expect(!statement.parameters.contains { ($0 as? String) == "now()" })
    }

    @Test("An inspector-only save reads a typed function name as the function on a timestamp, as text elsewhere")
    func sidebarSavePromotesTypedText() throws {
        let tabId = makeTable()
        coordinator.gridModel(forTab: tabId).selectRows([.existing(0)])

        let timestamp = try #require(try coordinator.sidebarEditStatements(editedFields: [
            InspectorFieldEdit(columnIndex: 2, columnName: "created_at", newValue: "NOW()")
        ]).first)
        #expect(timestamp.sql.contains("now()"))
        #expect(!timestamp.parameters.contains { ($0 as? String) == "NOW()" })

        let text = try #require(try coordinator.sidebarEditStatements(editedFields: [
            InspectorFieldEdit(columnIndex: 3, columnName: "name", newValue: "NOW()")
        ]).first)
        #expect(!text.sql.contains("NOW()"))
        #expect(text.parameters.contains { ($0 as? String) == "NOW()" })
    }
}
