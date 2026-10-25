//
//  MultiRowEditStateSetValueTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct MultiRowEditStateSetValueTests {
    private static let columns = ["id", "created_at", "name"]
    private static let columnTypes: [ColumnType] = [
        .text(rawType: "uuid"), .timestamp(rawType: "timestamptz"), .text(rawType: "varchar")
    ]

    private func makeState(
        columnTypes: [ColumnType]? = nil,
        rows: [[String?]] = [[nil, nil, "Alice"]],
        rowIDs: [RowID] = [.existing(0)],
        expressionCells: [Set<Int>] = [],
        externallyModifiedColumns: Set<Int> = [],
        foreignKeyColumns: Set<String> = [],
        nonNullableColumns: Set<String> = [],
        serverAssignedColumns: Set<String> = [],
        displayFormats: [ValueDisplayFormat?] = [],
        declaredTypes: [String: String] = [:],
        databaseType: DatabaseType? = .postgresql,
        cellWriter: CellWriterSupport = .host
    ) -> MultiRowEditState {
        let state = MultiRowEditState()
        state.configure(
            rowIDs: rowIDs,
            allRows: rows,
            expressionCells: expressionCells,
            columns: Self.columns,
            columnTypes: columnTypes ?? Self.columnTypes,
            externallyModifiedColumns: externallyModifiedColumns,
            foreignKeyColumns: foreignKeyColumns,
            nonNullableColumns: nonNullableColumns,
            serverAssignedColumns: serverAssignedColumns,
            displayFormats: displayFormats,
            declaredTypes: declaredTypes,
            databaseType: databaseType,
            cellWriter: cellWriter
        )
        return state
    }

    private func commands(_ state: MultiRowEditState, at index: Int) -> [SetValueCommand] {
        state.setValueCommands(for: state.fields[index], isWritable: true)
    }

    private func expressionSQL(_ commands: [SetValueCommand]) -> [String] {
        commands.compactMap { command in
            guard case .expression(let expression) = command else { return nil }
            return expression.sql
        }
    }

    private static let now = CellExpression("now()", kinds: [.timestamp, .datetime])

    // MARK: - Gating

    @Test("Set NULL and Control-Option-N are offered only on a nullable column")
    func nullFollowsNullability() {
        let nullable = makeState()
        let notNull = makeState(nonNullableColumns: ["name"])

        #expect(commands(nullable, at: 2).contains(.null))
        #expect(!commands(notNull, at: 2).contains(.null))
        #expect(InspectorFieldListView.stateShortcutCommand(for: "n", offered: commands(nullable, at: 2)) == .null)
        #expect(InspectorFieldListView.stateShortcutCommand(for: "n", offered: commands(notNull, at: 2)) == nil)
    }

    @Test("Set DEFAULT and Control-Option-D are offered only where the server fills the column")
    func defaultFollowsTheServer() {
        let noDefault = makeState()
        let withDefault = makeState(serverAssignedColumns: ["created_at"])

        #expect(!commands(noDefault, at: 1).contains(.defaultValue))
        #expect(commands(withDefault, at: 1).contains(.defaultValue))
        #expect(InspectorFieldListView.stateShortcutCommand(for: "d", offered: commands(noDefault, at: 1)) == nil)
        #expect(
            InspectorFieldListView.stateShortcutCommand(for: "d", offered: commands(withDefault, at: 1))
                == .defaultValue
        )
    }

    @Test("On SQLite, Set DEFAULT is offered on a new row and not on a saved one")
    func defaultOnSQLiteNeedsANewRow() {
        let saved = makeState(serverAssignedColumns: ["created_at"], databaseType: .sqlite)
        let inserted = makeState(
            rowIDs: [.inserted(UUID())], serverAssignedColumns: ["created_at"], databaseType: .sqlite
        )

        #expect(!commands(saved, at: 1).contains(.defaultValue))
        #expect(commands(inserted, at: 1).contains(.defaultValue))
    }

    @Test("Generate UUID is offered on a uuid column, and not on a foreign key, text, or a writer without UUID text")
    func generateUUIDFollowsTheColumn() {
        let state = makeState()
        #expect(commands(state, at: 0).contains(.uuid(.v4)))
        #expect(commands(state, at: 0).contains(.uuid(.v7)))
        #expect(!commands(state, at: 2).contains(.uuid(.v4)))

        let foreignKey = makeState(foreignKeyColumns: ["id"])
        #expect(!commands(foreignKey, at: 0).contains(.uuid(.v4)))

        let oldDriver = makeState(cellWriter: .none)
        #expect(!commands(oldDriver, at: 0).contains(.uuid(.v4)))
    }

    @Test("SQL Functions are the vocabulary's for the column, and none for a text column or a writer without SQL")
    func functionsFollowTheVocabulary() {
        let state = makeState()
        #expect(expressionSQL(commands(state, at: 1)) == ["now()", "CURRENT_TIMESTAMP", "LOCALTIMESTAMP"])
        #expect(expressionSQL(commands(state, at: 2)).isEmpty)

        let noSQL = makeState(cellWriter: CellWriterSupport(acceptsExpressions: false, acceptsUUIDText: true))
        #expect(expressionSQL(commands(noSQL, at: 1)).isEmpty)
    }

    @Test("A read-only field, or one with no engine to ask, offers nothing")
    func nothingWithoutAWritableField() {
        let state = makeState()
        #expect(state.setValueCommands(for: state.fields[2], isWritable: false).isEmpty)

        let dataFile = makeState(databaseType: nil, cellWriter: .none)
        #expect(commands(dataFile, at: 2).isEmpty)
    }

    // MARK: - Expressions

    @Test("A function picked from the menu goes out as SQL, and the inspector-only save is told so")
    func pickedFunctionIsAnExpression() {
        let state = makeState()
        var sent: [(index: Int, sql: String, continuity: FieldEditContinuity)] = []
        state.onFieldExpressionChanged = { sent.append(($0, $1, $2)) }
        state.onFieldChanged = { _, _, _ in Issue.record("a function must not go out as a literal") }

        state.setValue(.expression(Self.now), at: 1)

        #expect(sent.count == 1)
        #expect(sent.first?.index == 1)
        #expect(sent.first?.sql == "now()")
        #expect(sent.first?.continuity == .discrete)
        #expect(state.fields[1].isPendingExpression)
        #expect(FieldValueState.resolve(state.fields[1]) == .value("now()"))
        #expect(state.getEditedFields() == [
            InspectorFieldEdit(columnIndex: 1, columnName: "created_at", newValue: "now()", isExpression: true)
        ])
    }

    @Test("Set NULL over a picked function is no longer SQL")
    func nullClearsTheExpression() {
        let state = makeState()
        state.onFieldExpressionChanged = { _, _, _ in }
        state.onFieldChanged = { _, _, _ in }

        state.setValue(.expression(Self.now), at: 1)
        state.setValue(.null, at: 1)

        #expect(!state.fields[1].isPendingExpression)
        #expect(state.fields[1].isPendingNull)
    }

    @Test("A function name typed on a timestamp column stages the vocabulary's SQL and keeps the typed text")
    func typedFunctionIsPromoted() {
        let state = makeState(
            columnTypes: [.text(rawType: "CHAR(36)"), .datetime(rawType: "DATETIME"), .text(rawType: "VARCHAR(20)")],
            databaseType: .mysql
        )
        var literals: [PluginCellValue] = []
        var expressions: [(sql: String, continuity: FieldEditContinuity)] = []
        state.onFieldChanged = { _, value, _ in literals.append(value) }
        state.onFieldExpressionChanged = { _, sql, continuity in expressions.append((sql, continuity)) }

        state.updateField(at: 1, value: "now(")
        state.updateField(at: 1, value: "now()")

        #expect(literals == [.text("now(")])
        #expect(expressions.map { $0.sql } == ["NOW()"])
        #expect(expressions.first?.continuity == .typing)
        #expect(state.fields[1].pendingValue == "now()")
        #expect(!state.fields[1].isPendingExpression)
    }

    @Test(
        "A function name typed on a text column, or for a writer without SQL, stays text",
        arguments: zip([2, 1], [CellWriterSupport.host, CellWriterSupport.none])
    )
    func typedFunctionStaysTextWhereItCannotRun(column: Int, writer: CellWriterSupport) {
        let state = makeState(cellWriter: writer)
        var literals: [PluginCellValue] = []
        state.onFieldChanged = { _, value, _ in literals.append(value) }
        state.onFieldExpressionChanged = { _, _, _ in Issue.record("typed text must stay text here") }

        state.updateField(at: column, value: "now()")

        #expect(literals == [.text("now()")])
    }

    @Test("A value window over rows that are no longer selected promotes typed text the same way")
    func detachedTypedFunctionIsPromoted() {
        let state = makeState()
        var detached: [(value: PluginCellValue, rowIDs: [RowID], isExpression: Bool)] = []
        state.onDetachedFieldChanged = { _, value, rowIDs, isExpression in detached.append((value, rowIDs, isExpression)) }

        state.updateDetachedField(columnIndex: 1, rowIDs: [.existing(5)], value: "CURRENT_TIMESTAMP")
        state.updateDetachedField(columnIndex: 2, rowIDs: [.existing(5)], value: "now()")

        #expect(detached.count == 2)
        #expect(detached.first?.value == .text("CURRENT_TIMESTAMP"))
        #expect(detached.first?.isExpression == true)
        #expect(detached.last?.value == .text("now()"))
        #expect(detached.last?.isExpression == false)
    }

    // The grid staged `now()`; the user types over it in the inspector, then types it back.
    @Test("Clearing a field back to the SQL its rows held sends it back as SQL, not as text")
    func revertKeepsTheExpression() {
        let rowID = RowID.existing(0)
        let state = makeState(
            rows: [[nil, "now()", "Alice"]], rowIDs: [rowID], expressionCells: [[1]], externallyModifiedColumns: [1]
        )
        #expect(state.fields[1].isPendingExpression)
        #expect(state.fields[1].pendingValue == "now()")

        var reverted: (values: [RowID: PluginCellValue], expressionRows: Set<RowID>)?
        state.onFieldChanged = { _, _, _ in }
        state.onFieldReverted = { _, values, _, expressionRows in reverted = (values, expressionRows) }

        state.updateField(at: 1, value: "2024-01-01 00:00:00")
        state.updateField(at: 1, value: "now()")

        #expect(reverted?.values == [rowID: .text("now()")])
        #expect(reverted?.expressionRows == [rowID])
    }

    @Test("Rows that hold the same text, one as SQL and one not, read as Multiple values")
    func expressionStateIsPartOfTheValue() {
        let state = makeState(
            rows: [[nil, "now()", "a"], [nil, "now()", "a"]],
            rowIDs: [.existing(0), .existing(1)],
            expressionCells: [[1], []]
        )

        #expect(state.fields[1].hasMultipleValues)
        #expect(!state.fields[2].hasMultipleValues)
    }

    // MARK: - Generate UUID

    @Test("Generate UUID on one row stages one lowercase UUID as a discrete step")
    func generateUUIDOnOneRow() throws {
        let state = makeState()
        var sent: [(value: PluginCellValue, continuity: FieldEditContinuity)] = []
        state.onFieldChanged = { _, value, continuity in sent.append((value, continuity)) }

        state.setValue(.uuid(.v4), at: 0)

        let text = try #require(sent.first?.value.asText)
        #expect(UUID(uuidString: text) != nil)
        #expect(text == text.lowercased())
        #expect(sent.first?.continuity == .discrete)
        #expect(state.fields[0].pendingValue == text)
    }

    @Test("Generate UUID on a lengthless CHAR column with no values takes the length its schema declares")
    func generateUUIDTakesTheSchemaLength() throws {
        let state = makeState(
            columnTypes: [.text(rawType: "CHAR"), .datetime(rawType: "DATETIME"), .text(rawType: "VARCHAR(20)")],
            displayFormats: [.uuid, nil, nil],
            declaredTypes: ["id": "CHAR(32)"],
            databaseType: .mysql
        )
        var sent: [PluginCellValue] = []
        state.onFieldChanged = { _, value, _ in sent.append(value) }

        state.setValue(.uuid(.v4), at: 0)

        let text = try #require(sent.first?.asText)
        #expect(text.count == 32)
        #expect(text.allSatisfy { $0.isHexDigit })
    }

    @Test("Generate UUID on a BINARY(16) column shown as UUID stages 16 bytes")
    func generateUUIDInBytes() {
        let state = makeState(
            columnTypes: [.blob(rawType: "BINARY(16)"), .datetime(rawType: "DATETIME"), .text(rawType: "VARCHAR(20)")],
            displayFormats: [.uuid, nil, nil],
            databaseType: .mysql
        )
        var sent: [PluginCellValue] = []
        state.onFieldChanged = { _, value, _ in sent.append(value) }

        state.setValue(.uuid(.v4), at: 0)

        guard case .bytes(let data) = sent.first else {
            Issue.record("expected bytes, got \(String(describing: sent.first))")
            return
        }
        #expect(data.count == 16)
    }

    @Test("Generate UUID over several rows gives each row its own, and the field reads Multiple values")
    func generateUUIDPerRow() throws {
        let rowIDs: [RowID] = [.existing(0), .existing(1), .existing(2)]
        let state = makeState(rows: [[nil, nil, "a"], [nil, nil, "b"], [nil, nil, "c"]], rowIDs: rowIDs)
        var perRow: [RowID: PluginCellValue] = [:]
        state.onFieldValuesChanged = { _, values in perRow = values }
        state.onFieldChanged = { _, _, _ in Issue.record("one value must not go to every row") }

        state.setValue(.uuid(.v7), at: 0)

        #expect(Set(perRow.keys) == Set(rowIDs))
        let texts = perRow.values.compactMap { $0.asText }
        #expect(Set(texts).count == 3)
        for text in texts {
            let uuid = try #require(UUID(uuidString: text))
            #expect(uuid.uuid.6 >> 4 == 7)
        }
        #expect(FieldValueState.resolve(state.fields[0]) == .multipleValues)
        #expect(state.fields[0].pendingValue == nil)
        #expect(state.fields[0].hasCommittedEdit)
        #expect(state.getEditedFields().isEmpty)
    }

    @Test("Typing into the field after a per-row generate writes the typed value for every row")
    func typingAfterPerRowGenerate() {
        let state = makeState(rows: [[nil, nil, "a"], [nil, nil, "b"]], rowIDs: [.existing(0), .existing(1)])
        state.onFieldValuesChanged = { _, _ in }
        var typed: [PluginCellValue] = []
        state.onFieldChanged = { _, value, _ in typed.append(value) }

        state.setValue(.uuid(.v4), at: 0)
        state.updateField(at: 0, value: "6f1c2a7e-0d3b-4c5f-9a8e-1b2c3d4e5f60")

        #expect(typed == [.text("6f1c2a7e-0d3b-4c5f-9a8e-1b2c3d4e5f60")])
        #expect(state.fields[0].pendingValue == "6f1c2a7e-0d3b-4c5f-9a8e-1b2c3d4e5f60")
    }

    @Test("Clearing a value typed over per-row UUIDs puts each row's own UUID back")
    func clearingAfterPerRowGenerate() {
        let state = makeState(rows: [[nil, nil, "a"], [nil, nil, "b"]], rowIDs: [.existing(0), .existing(1)])
        var generated: [RowID: PluginCellValue] = [:]
        var reverted: [RowID: PluginCellValue] = [:]
        state.onFieldValuesChanged = { _, values in generated = values }
        state.onFieldChanged = { _, _, _ in }
        state.onFieldReverted = { _, values, _, _ in reverted = values }

        state.setValue(.uuid(.v4), at: 0)
        state.updateField(at: 0, value: "x")
        state.updateField(at: 0, value: "")

        #expect(generated.count == 2)
        #expect(reverted == generated)
    }

    // `configure` wrote `originalValue ?? ""` as the pending value, so rows that disagreed showed an empty value.
    @Test("A modified column the rows disagree on reads Multiple values, not an empty pending value")
    func modifiedMultiValuedFieldReadsMultipleValues() {
        let state = makeState(
            rows: [[nil, nil, "a"], [nil, nil, "b"]],
            rowIDs: [.existing(0), .existing(1)],
            externallyModifiedColumns: [2]
        )

        #expect(FieldValueState.resolve(state.fields[2]) == .multipleValues)
        #expect(state.fields[2].pendingValue == nil)
        #expect(state.fields[2].hasCommittedEdit)
        #expect(state.getEditedFields().isEmpty)
    }
}
