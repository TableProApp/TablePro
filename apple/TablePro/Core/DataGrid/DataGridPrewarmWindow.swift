//
//  DataGridPrewarmWindow.swift
//  TablePro
//
//  The slice of a result the data grid formats ahead of the viewport.
//

import AppKit
import TableProPluginKit

/// The rows the background prewarm may format, as a function of the rows on screen.
///
/// Kept apart from the coordinator so the bound can be asserted without an `NSTableView`.
enum DataGridPrewarmWindow {
    static let margin = 250

    static func rows(around visible: Range<Int>, displayCount: Int) -> Range<Int> {
        guard displayCount > 0 else { return 0..<0 }
        let lower = max(0, min(visible.lowerBound, displayCount) - margin)
        let upper = min(displayCount, max(visible.lowerBound, visible.upperBound) + margin)
        guard lower < upper else { return 0..<0 }
        return lower..<upper
    }
}

// What a wrapping grid's rows are measured against, copied out so a batch counts their lines where it formats them.
struct DataGridPrewarmWrap: Sendable {
    struct Column: Sendable {
        let dataIndex: Int
        let width: CGFloat
        let kind: DataGridCellKind
    }

    let columns: [Column]
    let face: DataGridWrapLayout.Face
    let isEditable: Bool
    let marksEmptyText: Bool
    let marksInvisibles: Bool
    // Rows with a pending change or a value left on the server draw text the batch cannot see.
    let measurableRows: Set<RowID>
    let generation: Int

    // Nil leaves the row to the main actor: a marked character is as wide as its marker, which is laid out there.
    func lineCount(of row: Row, texts: ContiguousArray<String?>) -> Int? {
        guard measurableRows.contains(row.id) else { return nil }
        var lines = 1
        for column in columns where column.dataIndex < row.values.count && column.dataIndex < texts.count {
            let rawValue = row.values[column.dataIndex]
            guard column.kind != .checkbox,
                  DataGridCellContent.placeholder(for: rawValue, marksEmptyText: marksEmptyText) == nil,
                  let text = texts[column.dataIndex] else { continue }
            let accessory = DataGridCellAccessory.visible(for: column.kind, isEditable: isEditable, rawValue: rawValue.asText)
            let width = accessory.availableTextWidth(in: NSRect(x: 0, y: 0, width: column.width, height: 0))
            if marksInvisibles {
                let shown = DataGridWrapLayout.bounded(text, width: width, pointSize: face.font.pointSize).text
                guard !DataGridWrapLayout.holdsMarkableCharacter(shown) else { return nil }
            }
            lines = max(lines, DataGridWrapLayout.lineCount(of: text, width: width, face: face))
            if lines >= DataGridWrapLayout.maximumLines { break }
        }
        return lines
    }
}

// A few rows of the window, copied out so the formatting never holds the result's whole buffer: an edit made
// meanwhile would then copy every row.
struct DataGridPrewarmBatch: Sendable {
    static let rowLimit = 32

    let rows: [Row]
    // A cut text holds NULL in its row and shows its first characters, which the rows keep beside their values.
    var unloadedHeads: [RowID: [Int: String]] = [:]
    let columnCount: Int
    let columnTypes: [ColumnType]
    let formats: [ValueDisplayFormat?]
    let databaseType: DatabaseType?
    let dateFormat: DateFormatOption
    // What the display cache had dropped when the rows were copied; text formatted before a later drop is stale.
    let invalidations: Int
    var keepsLineBreaks = false
    var wrap: DataGridPrewarmWrap?

    // A renderer serves one thread, so each batch builds its own from the format.
    @concurrent
    nonisolated func formatted() async -> sending [(id: RowID, box: RowDisplayBox, lineCount: Int?)] {
        let dates = DateDisplayRenderer(format: dateFormat)
        var formatted: [(id: RowID, box: RowDisplayBox, lineCount: Int?)] = []
        formatted.reserveCapacity(rows.count)
        for row in rows where !Task.isCancelled {
            let box = RowDisplayBox(ContiguousArray<String?>(repeating: nil, count: columnCount))
            let heads = unloadedHeads[row.id] ?? [:]
            for dataIndex in 0..<min(row.values.count, columnCount) {
                let shown = heads[dataIndex].map(PluginCellValue.text) ?? row.values[dataIndex]
                let display = CellDisplayFormatter.display(
                    shown,
                    columnType: dataIndex < columnTypes.count ? columnTypes[dataIndex] : nil,
                    displayFormat: dataIndex < formats.count ? formats[dataIndex] : nil,
                    databaseType: databaseType,
                    dates: dates,
                    keepsLineBreaks: keepsLineBreaks
                )
                box.setText(display.text ?? shown.asText ?? "", at: dataIndex, isFormatted: display.isFormatted)
            }
            formatted.append((row.id, box, wrap?.lineCount(of: row, texts: box.values)))
        }
        return formatted
    }
}
