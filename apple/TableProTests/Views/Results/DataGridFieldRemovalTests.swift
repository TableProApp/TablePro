import AppKit
@testable import TablePro
import TableProPluginKit
import Testing

extension GlobalStateSuites {
    @Suite(.recordingClipboard)
    @MainActor
    struct DataGridFieldRemovalTests {
        private static let columns = ["_id", "nick", "deletedAt"]

        private func makeGrid(supportsFieldRemoval: Bool = true) -> CommandGrid {
            var configuration = CommandGrid.editable(databaseType: .mongodb)
            configuration.traits.supportsFieldRemoval = supportsFieldRemoval
            return CommandGrid(
                TableRows.from(
                    queryRows: [["1", "Ada", .null]],
                    columns: Self.columns,
                    columnTypes: Array(repeating: .text(rawType: nil), count: Self.columns.count),
                    absentCells: [0: [2]]
                ),
                configuration: configuration
            )
        }

        private func cell(_ grid: CommandGrid, _ column: Int) throws -> DataGridCommandCell {
            DataGridCommandCell(rowID: .existing(0), row: 0, column: try #require(grid.model.columns.column(at: column)))
        }

        @Test("A missing field draws as no field, not as NULL")
        func missingFieldIsNamed() {
            #expect(DataGridCellContent.placeholder(for: .null, isAbsent: true) == .absent)
            #expect(DataGridCellContent.placeholder(for: .null) == .null)
        }

        @Test("Remove Field takes the field out of the row as one commit")
        func removeFieldStagesTheRemoval() throws {
            let grid = makeGrid()

            grid.commands.removeField(try cell(grid, 1))

            #expect(grid.owner.tableRows.isAbsent(row: 0, column: 1))
            let edit = try #require(grid.owner.commits.first?.edits.first)
            #expect(edit.oldValue == "Ada" && !edit.absence.wasAbsent)
            #expect(edit.absence.isAbsent)
            #expect(edit.newValue == .null)
        }

        @Test("The cell's menu offers Remove Field only while the field is there")
        func menuOffersRemovalOnPresentFields() {
            let grid = makeGrid()

            #expect(CommandRows.titles(grid.rowMenu(row: 0, displayColumn: 1)).contains(String(localized: "Remove Field")))
            #expect(!CommandRows.titles(grid.rowMenu(row: 0, displayColumn: 2)).contains(String(localized: "Remove Field")))
        }

        @Test("Set NULL on a missing field puts the field back holding null")
        func nullOverMissingFieldIsAnEdit() throws {
            let grid = makeGrid()

            grid.commands.applySetValue(.null, to: [try cell(grid, 2)])

            #expect(!grid.owner.tableRows.isAbsent(row: 0, column: 2))
            let edit = try #require(grid.owner.commits.first?.edits.first)
            #expect(edit.absence.wasAbsent && !edit.absence.isAbsent)
            #expect(edit.newValue == .null)
        }

        @Test("Copy with Headers records which fields each copied row lacked")
        func copyWithHeadersCarriesAbsence() throws {
            let grid = makeGrid()
            let clipboard = try #require(RecordingClipboard.current)
            grid.selectRows(0...0)

            grid.controller.copyRowsWithHeaders(nil)

            let payload = try #require(clipboard.gridRows)
            #expect(payload.columns == Self.columns)
            #expect(payload.rows == [["1", "Ada", .null]])
            #expect(payload.absentCells == [0: [2]])
        }

        @Test("An engine that cannot tell a missing field from NULL offers no removal")
        func removalNeedsTheCapability() throws {
            let grid = makeGrid(supportsFieldRemoval: false)
            let nick = try cell(grid, 1)

            grid.commands.removeField(nick)

            #expect(!grid.commands.canRemoveField(nick))
            #expect(!grid.owner.tableRows.isAbsent(row: 0, column: 1))
            #expect(grid.owner.commits.isEmpty)
            #expect(!CommandRows.titles(grid.rowMenu(row: 0, displayColumn: 1)).contains(String(localized: "Remove Field")))
        }
    }
}
