//
//  FillColumnTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct FillColumnTests {
    private func makeGrid(
        columns: [String],
        rowCount: Int,
        isEditable: Bool = true,
        columnTypes: [ColumnType]? = nil,
        columnNullable: [String: Bool] = [:],
        databaseType: DatabaseType? = .postgresql
    ) -> CommandGrid {
        let types = columnTypes ?? Array(repeating: .text(rawType: nil), count: columns.count)
        let rows = (0..<rowCount).map { row in (0..<columns.count).map { PluginCellValue.text("r\(row)c\($0)") } }
        return CommandGrid(
            TableRows.from(queryRows: rows, columns: columns, columnTypes: types, columnNullable: columnNullable),
            configuration: isEditable ? CommandGrid.editable(databaseType: databaseType) : CommandGrid.readOnly()
        )
    }

    private func column(_ grid: CommandGrid, _ index: Int) -> DataGridColumn {
        grid.model.columns.columns[index]
    }

    // MARK: - Targets

    @Test("Targets every loaded row when editable and none are deleted")
    func targetsEveryRow() {
        let grid = makeGrid(columns: ["a"], rowCount: 3)
        #expect(grid.commands.fillTargetRowIDs() == [.existing(0), .existing(1), .existing(2)])
    }

    @Test("Excludes rows marked for deletion")
    func excludesDeletedRows() {
        let grid = makeGrid(columns: ["a"], rowCount: 3)
        grid.owner.changeManager.recordRowDeletion(rowID: .existing(1), originalRow: [.text("r1c0")])

        #expect(grid.commands.fillTargetRowIDs() == [.existing(0), .existing(2)])
    }

    @Test("Targets nothing on a read-only result, and is not offered there or without rows")
    func targetsNothingWhenReadOnly() {
        let readOnly = makeGrid(columns: ["a"], rowCount: 3, isEditable: false)
        #expect(readOnly.commands.fillTargetRowIDs().isEmpty)
        #expect(!readOnly.commands.canFillColumn(column(readOnly, 0)))

        let empty = makeGrid(columns: ["a"], rowCount: 0)
        #expect(!empty.commands.canFillColumn(column(empty, 0)))
    }

    // MARK: - Value resolution

    @Test("Resolves NULL distinctly from an empty string")
    func resolvesNullDistinctFromEmpty() {
        let grid = makeGrid(columns: ["a"], rowCount: 1)
        let target = column(grid, 0)

        #expect(grid.commands.fillColumnContent(choice: .null, text: "ignored", column: target) == .value(.null))
        #expect(grid.commands.fillColumnContent(choice: .value, text: "", column: target) == .value(.text("")))
        #expect(grid.commands.fillColumnContent(choice: .value, text: "active", column: target) == .value(.text("active")))
    }

    @Test("Offers NULL where the column takes it, and the UUIDs only on a column that holds them")
    func choicesFollowTheColumn() {
        let grid = makeGrid(
            columns: ["id", "name", "code"],
            rowCount: 1,
            columnTypes: [.text(rawType: "uuid"), .text(rawType: "text"), .text(rawType: "text")],
            columnNullable: ["id": false, "name": true, "code": false]
        )

        #expect(grid.commands.fillColumnChoices(for: column(grid, 0)) == [.value, .uuid(.v4), .uuid(.v7)])
        #expect(grid.commands.fillColumnChoices(for: column(grid, 1)) == [.value, .null])
        #expect(grid.commands.fillColumnChoices(for: column(grid, 2)) == [.value])
    }

    @Test("A typed function on a date column fills as SQL, and the same text on a text column as text")
    func typedFunctionFillsAsExpression() {
        let grid = makeGrid(
            columns: ["seen", "note"],
            rowCount: 1,
            columnTypes: [.timestamp(rawType: "timestamptz"), .text(rawType: "text")]
        )

        #expect(
            grid.commands.fillColumnContent(choice: .value, text: " NOW() ", column: column(grid, 0))
                == .value(.text("now()"), isExpression: true)
        )
        #expect(grid.commands.fillColumnContent(choice: .value, text: "NOW()", column: column(grid, 1)) == .value(.text("NOW()")))
    }

    @Test("Impact description reflects singular and plural counts")
    func impactDescriptionSingularAndPlural() {
        #expect(DataGridCommands.fillImpactDescription(rowCount: 1).contains("1 loaded row"))
        #expect(DataGridCommands.fillImpactDescription(rowCount: 42).contains("42 loaded rows"))
    }

    // MARK: - Apply

    @Test("One commit named Fill Column with a change per loaded row, other columns untouched")
    func appliesToEveryLoadedRow() {
        let grid = makeGrid(columns: ["a", "b"], rowCount: 4)

        grid.commands.applyFillColumn(column(grid, 0), content: .value(.text("X")))

        #expect(grid.owner.commits.map { $0.actionName } == [String(localized: "Fill Column")])
        for row in 0..<4 {
            #expect(grid.owner.staged(row, 0)?.value == .text("X"))
            #expect(grid.owner.staged(row, 1) == nil)
        }
    }

    @Test("Does not touch rows marked for deletion")
    func skipsDeletedRowsOnApply() {
        let grid = makeGrid(columns: ["a"], rowCount: 4)
        grid.owner.changeManager.recordRowDeletion(rowID: .existing(2), originalRow: [.text("r2c0")])

        grid.commands.applyFillColumn(column(grid, 0), content: .value(.text("X")))

        #expect(grid.owner.staged(0, 0)?.value == .text("X"))
        #expect(grid.owner.staged(2, 0) == nil)
    }

    @Test("Records nothing on a read-only result")
    func recordsNothingWhenReadOnly() {
        let grid = makeGrid(columns: ["a"], rowCount: 4, isEditable: false)

        grid.commands.applyFillColumn(column(grid, 0), content: .value(.text("X")))

        #expect(grid.owner.commits.isEmpty)
    }

    @Test("Writes NULL as a null change, not an empty string")
    func appliesNull() {
        let grid = makeGrid(columns: ["a"], rowCount: 2)

        grid.commands.applyFillColumn(column(grid, 0), content: .value(.null))

        #expect(grid.owner.staged(0, 0)?.value == .null)
    }

    @Test("Skips rows whose value already equals the fill value")
    func skipsRowsAlreadyEqual() {
        let grid = makeGrid(columns: ["a"], rowCount: 2)

        grid.commands.applyFillColumn(column(grid, 0), content: .value(.text("r0c0")))

        #expect(grid.owner.staged(0, 0) == nil)
        #expect(grid.owner.staged(1, 0)?.value == .text("r0c0"))
    }

    @Test("New UUID writes a different UUID into every row, in row order")
    func uuidFillDrawsOnePerRow() throws {
        let grid = makeGrid(columns: ["id"], rowCount: 3, columnTypes: [.text(rawType: "uuid")])
        let content = try #require(grid.commands.fillColumnContent(choice: .uuid(.v7), text: "", column: column(grid, 0)))

        grid.commands.applyFillColumn(column(grid, 0), content: content)

        let staged = (0..<3).compactMap { grid.owner.staged($0, 0)?.value.asText }
        #expect(staged.count == 3)
        #expect(Set(staged).count == 3)
        #expect(staged.allSatisfy { UUID(uuidString: $0) != nil && $0 == $0.lowercased() })
        #expect(staged == staged.sorted())
    }

    @Test("A fill function is staged as SQL on every row")
    func expressionFillIsMarked() {
        let grid = makeGrid(columns: ["seen"], rowCount: 2, columnTypes: [.timestamp(rawType: "timestamptz")])

        grid.commands.applyFillColumn(column(grid, 0), content: .value(.text("now()"), isExpression: true))

        #expect(grid.owner.staged(0, 0)?.isExpression == true)
        #expect(grid.owner.staged(1, 0)?.isExpression == true)
    }

    @Test("No UUID content on a column that holds none")
    func uuidFillRefusedOnText() {
        let grid = makeGrid(columns: ["name"], rowCount: 1, columnTypes: [.text(rawType: "text")])

        #expect(grid.commands.fillColumnContent(choice: .uuid(.v4), text: "", column: column(grid, 0)) == nil)
    }
}
