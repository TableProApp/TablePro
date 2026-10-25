import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

extension GlobalStateSuites {
    @Suite(.recordingClipboard)
    @MainActor
    struct GridSelectionCopyTruncationTests {
        private func grid(rowCount: Int) -> CommandGrid {
            CommandGrid(TableRows.from(
                queryRows: (0..<rowCount).map { [.text("\($0)"), .text("v\($0)")] },
                columns: ["id", "value"],
                columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT")]
            ))
        }

        private static func block(rowCount: Int) -> GridSelection {
            .single(
                GridRect(rows: 0...(rowCount - 1), columns: 0...1),
                anchor: GridCoord(row: 0, displayColumn: 0),
                active: GridCoord(row: rowCount - 1, displayColumn: 1)
            )
        }

        @Test("a cell copy cut at the row cap says how many rows it left out")
        func copyPastTheCapSaysSo() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let cap = RowOperationsManager.maxClipboardRows
            let rowCount = cap + 2

            let commandGrid = grid(rowCount: rowCount)
            commandGrid.commands.copyRange(Self.block(rowCount: rowCount))

            let lines = clipboard.text?.components(separatedBy: "\n") ?? []
            #expect(lines.count == cap + 1)
            #expect(lines.first == "0\tv0")
            #expect(lines.dropLast().last == "\(cap - 1)\tv\(cap - 1)")
            #expect(lines.last == "(truncated, showing first \(cap) of \(rowCount) rows)")
        }

        @Test("a cell copy under the cap carries no notice")
        func copyUnderTheCapHasNoNotice() throws {
            let clipboard = try #require(RecordingClipboard.current)

            let commandGrid = grid(rowCount: 3)
            commandGrid.commands.copyRange(Self.block(rowCount: 3))

            #expect(clipboard.text == "0\tv0\n1\tv1\n2\tv2")
        }
    }
}
