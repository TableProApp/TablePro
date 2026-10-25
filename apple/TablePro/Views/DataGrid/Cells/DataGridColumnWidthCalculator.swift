//
//  DataGridColumnWidthCalculator.swift
//  TablePro
//

import AppKit
import TableProPluginKit
import TableProTextEngine

@MainActor
struct DataGridColumnWidthCalculator {
    private static let minColumnWidth: CGFloat = 60
    private static let maxColumnWidth: CGFloat = 800
    private static let minFitToContentWidth: CGFloat = 300
    private static let fitToContentViewportFraction: CGFloat = 0.5
    private static let sampleRowCount = 30
    private static let wideResultSampleRowCount = 10
    private static let wideResultColumnCount = 50
    private static let fitToContentValueBudget = 200_000
    private static let maxMeasureChars = 50
    private static let headerPadding: CGFloat = 48
    private static let headerCharWidthRatio: CGFloat = 0.75

    struct Input {
        let column: DataGridColumn
        let accessory: DataGridCellAccessory
        let displayFormat: ValueDisplayFormat?
    }

    private struct Budget {
        let cap: CGFloat
        let measuredCharLimit: Int
        let sampledRows: Int
    }

    let rows: TableRows
    let databaseType: DatabaseType?
    let nullDisplayString: String
    let revealsInvisibleCharacters: Bool
    let fonts: DataGridFontCache

    static func fitToContentCap(availableWidth: CGFloat) -> CGFloat {
        let proportional = availableWidth * fitToContentViewportFraction
        return min(max(proportional, minFitToContentWidth), maxColumnWidth)
    }

    // The first paint samples, because it measures every column before the grid can draw a row.
    func automaticWidth(_ input: Input) -> CGFloat {
        let sampled = rows.columns.count > Self.wideResultColumnCount ? Self.wideResultSampleRowCount : Self.sampleRowCount
        return measure(input, budget: Budget(cap: Self.maxColumnWidth, measuredCharLimit: Self.maxMeasureChars, sampledRows: sampled))
    }

    // An explicit fit reads the page, bounded across the whole gesture so fitting every column of a wide result stays cheap.
    func fittedWidth(_ input: Input, availableWidth: CGFloat, fittedColumnCount: Int = 1) -> CGFloat {
        let cap = Self.fitToContentCap(availableWidth: availableWidth)
        let charWidth = fonts.monoCharWidth
        let limit = charWidth > 0 ? Int((cap / charWidth).rounded(.up)) : Self.maxMeasureChars
        let sampled = max(Self.sampleRowCount, Self.fitToContentValueBudget / max(1, fittedColumnCount))
        return measure(input, budget: Budget(cap: cap, measuredCharLimit: limit, sampledRows: sampled))
    }

    // Whole points: NSTableView pixel-aligns a fractional width during layout and reports it as a resize (measured).
    private func measure(_ input: Input, budget: Budget) -> CGFloat {
        measuredWidth(input, budget: budget).rounded(.up)
    }

    private func measuredWidth(_ input: Input, budget: Budget) -> CGFloat {
        let charWidth = fonts.monoCharWidth
        let dataIndex = input.column.dataIndex
        let headerCharCount = (input.column.name as NSString).length
        var maxWidth = CGFloat(headerCharCount) * charWidth * Self.headerCharWidthRatio + Self.headerPadding

        let totalRows = rows.count
        let step = max(1, totalRows / max(1, budget.sampledRows))

        for index in stride(from: 0, to: totalRows, by: step) {
            let rawValue = rows.value(at: index, column: dataIndex)
            let formatted = CellDisplayFormatter.format(
                rawValue,
                columnType: input.column.type,
                displayFormat: input.displayFormat,
                databaseType: databaseType
            ) ?? ""
            let placeholder = DataGridCellContent.placeholder(
                for: rawValue,
                isAbsent: rows.isAbsent(row: index, column: dataIndex),
                unloadedByteCount: rows.unloadedByteCount(row: index, column: dataIndex)
            )
            let value = DataGridCellContent.resolvedDisplayText(
                formatted,
                placeholder: placeholder,
                nullDisplayString: nullDisplayString
            )

            let charCount = min((value as NSString).length, budget.measuredCharLimit)
            let markedWidth = revealsInvisibleCharacters && placeholder == nil
                ? markedWidth(of: value, length: charCount)
                : nil
            let textWidth = markedWidth ?? CGFloat(charCount) * charWidth
            maxWidth = max(maxWidth, textWidth + input.accessory.measurementPadding)

            if maxWidth >= budget.cap {
                return budget.cap
            }
        }

        return min(max(maxWidth, Self.minColumnWidth), budget.cap)
    }

    // A mark is wider than the character it stands for, so a value holding one is laid out.
    private func markedWidth(of value: String, length: Int) -> CGFloat? {
        let text = value as NSString
        var index = 0
        while index < length {
            let unit = text.character(at: index)
            if unit == 0x0D || SpecialCharacter.mayBeSpecial(unit) { break }
            index += 1
        }
        guard index < length else { return nil }
        let marked = SpecialCharacterLine(
            NSAttributedString(string: text.substring(to: length), attributes: [.font: fonts.regular]),
            style: SpecialCharacterStyle(marksLineBreaks: true)
        )
        return CGFloat(CTLineGetTypographicBounds(marked.line, nil, nil, nil))
    }
}
