//
//  SelectionSummaryCalculator.swift
//  TablePro
//

import Foundation
import TableProNumberFormatting
import TableProPluginKit

actor SelectionSummaryCalculator {
    static let shared = SelectionSummaryCalculator()
    static let cancellationInterval = 4_096

    private struct BandColumn {
        let dataIndex: Int
        let rule: SelectionSummaryColumnRule
    }

    func summarize(_ input: SelectionSummaryInput) throws(CancellationError) -> SelectionSummary {
        var tally = Tally(input: input)
        let displayRowCount = input.displayIDs?.count ?? input.tableRows.count
        var budget = 0
        for band in Self.rowBands(of: input.selection, rowLimit: displayRowCount) {
            let columns = input.selection.columns(in: band.lowerBound).compactMap { position -> BandColumn? in
                guard input.dataColumnsByDisplayPosition.indices.contains(position) else { return nil }
                let dataIndex = input.dataColumnsByDisplayPosition[position]
                return BandColumn(dataIndex: dataIndex, rule: input.policy.rule(forColumn: dataIndex))
            }
            guard !columns.isEmpty else { continue }
            for displayRow in band {
                if budget <= 0 {
                    if Task.isCancelled { throw CancellationError() }
                    budget = Self.cancellationInterval
                }
                budget -= columns.count
                guard let storageIndex = DisplayRowMapping.rowIndex(
                    forDisplay: displayRow,
                    displayIDs: input.displayIDs,
                    in: input.tableRows
                ) else { continue }
                let row = input.tableRows.rows[storageIndex]
                guard !input.deletedRowIDs.contains(row.id) else { continue }
                for column in columns {
                    tally.add(row[column.dataIndex], column: column.dataIndex, rule: column.rule, rowID: row.id)
                }
            }
        }
        return tally.summary(coversWholeColumn: !input.selection.columns.isEmpty)
    }

    /// Every rectangle's row bounds are breakpoints, so the rectangles covering a band are the same
    /// on each of its rows: one column union per band counts an overlapped cell once.
    static func rowBands(of selection: GridSelection, rowLimit: Int) -> [Range<Int>] {
        guard rowLimit > 0 else { return [] }
        var bounds = Set<Int>()
        for rect in selection.rectangles {
            let lower = max(0, rect.rows.lowerBound)
            let upper = min(rowLimit - 1, rect.rows.upperBound)
            guard lower <= upper else { continue }
            bounds.insert(lower)
            bounds.insert(upper + 1)
        }
        let sorted = bounds.sorted()
        return zip(sorted, sorted.dropFirst()).map { $0..<$1 }
    }
}

private struct Tally {
    private static let defaultMarkerLength = PluginCellValue.defaultMarkerText.utf8.count

    let emptyTextIsEmpty: Bool
    let insertedRowIDs: Set<RowID>
    let modifiedCells: [RowID: Set<Int>]
    var valueCount = 0
    var emptyCount = 0
    var notANumberCount = 0
    var numbers = NumericSummaryAccumulator()

    init(input: SelectionSummaryInput) {
        emptyTextIsEmpty = input.policy.emptyTextIsEmpty
        insertedRowIDs = input.insertedRowIDs
        modifiedCells = input.modifiedCells
    }

    mutating func add(_ value: PluginCellValue, column: Int, rule: SelectionSummaryColumnRule, rowID: RowID) {
        switch value {
        case .null:
            emptyCount += 1
        case .bytes:
            valueCount += 1
        case .text(let text):
            guard !isEmpty(text, column: column, rowID: rowID) else {
                emptyCount += 1
                return
            }
            valueCount += 1
            guard !text.isEmpty else { return }
            switch rule {
            case .numeric:
                if !addNumber(text) { notANumberCount += 1 }
            case .numericIfParsable:
                _ = addNumber(text)
            case .countOnly:
                break
            }
        }
    }

    /// The accumulator trims only ASCII blanks. Column Statistics also takes a number padded with
    /// other Unicode spaces, and the two must agree on the same cells.
    private mutating func addNumber(_ text: String) -> Bool {
        if numbers.add(text) { return true }
        guard !text.utf8.allSatisfy({ $0 < 0x80 }) else { return false }
        return numbers.add(text.trimmingCharacters(in: .whitespaces))
    }

    /// The default marker is the grid's own placeholder only where an edit put it; anywhere else
    /// it is text the table holds.
    private func isEmpty(_ text: String, column: Int, rowID: RowID) -> Bool {
        if text.isEmpty { return emptyTextIsEmpty }
        guard text.utf8.count == Self.defaultMarkerLength, text == PluginCellValue.defaultMarkerText else {
            return false
        }
        return insertedRowIDs.contains(rowID) || modifiedCells[rowID]?.contains(column) == true
    }

    func summary(coversWholeColumn: Bool) -> SelectionSummary {
        SelectionSummary(
            valueCount: valueCount,
            emptyCount: emptyCount,
            notANumberCount: notANumberCount,
            numbers: numbers.summary(),
            coversWholeColumn: coversWholeColumn
        )
    }
}
