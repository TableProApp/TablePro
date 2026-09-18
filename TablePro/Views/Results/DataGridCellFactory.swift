//
//  DataGridCellFactory.swift
//  TablePro
//

import AppKit
import Foundation
import TableProPluginKit

@MainActor
final class DataGridCellFactory {
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

    private struct ColumnWidthBudget {
        let cap: CGFloat
        let measuredCharLimit: Int
        let sampledRows: Int
    }

    static func fitToContentCap(availableWidth: CGFloat) -> CGFloat {
        let proportional = availableWidth * fitToContentViewportFraction
        return min(max(proportional, minFitToContentWidth), maxColumnWidth)
    }

    func calculateOptimalColumnWidth(
        for columnName: String,
        columnIndex: Int,
        tableRows: TableRows,
        accessory: DataGridCellAccessory = .none,
        displayFormat: ValueDisplayFormat? = nil,
        databaseType: DatabaseType? = nil,
        isLargeDataset: Bool = false,
        nullDisplayString: String? = nil
    ) -> CGFloat {
        measureColumnWidth(
            for: columnName,
            columnIndex: columnIndex,
            tableRows: tableRows,
            accessory: accessory,
            displayFormat: displayFormat,
            databaseType: databaseType,
            isLargeDataset: isLargeDataset,
            nullDisplayString: nullDisplayString,
            budget: ColumnWidthBudget(
                cap: Self.maxColumnWidth,
                measuredCharLimit: Self.maxMeasureChars,
                sampledRows: Self.automaticSampleRowCount(columnCount: tableRows.columns.count)
            )
        )
    }

    func calculateFitToContentWidth(
        for columnName: String,
        columnIndex: Int,
        tableRows: TableRows,
        availableWidth: CGFloat,
        accessory: DataGridCellAccessory = .none,
        displayFormat: ValueDisplayFormat? = nil,
        databaseType: DatabaseType? = nil,
        isLargeDataset: Bool = false,
        nullDisplayString: String? = nil,
        fittedColumnCount: Int = 1
    ) -> CGFloat {
        let cap = Self.fitToContentCap(availableWidth: availableWidth)
        let charWidth = ThemeEngine.shared.dataGridFonts.monoCharWidth
        let measuredCharLimit = charWidth > 0 ? Int((cap / charWidth).rounded(.up)) : Self.maxMeasureChars

        return measureColumnWidth(
            for: columnName,
            columnIndex: columnIndex,
            tableRows: tableRows,
            accessory: accessory,
            displayFormat: displayFormat,
            databaseType: databaseType,
            isLargeDataset: isLargeDataset,
            nullDisplayString: nullDisplayString,
            budget: ColumnWidthBudget(
                cap: cap,
                measuredCharLimit: measuredCharLimit,
                sampledRows: Self.fitSampleRowCount(fittedColumnCount: fittedColumnCount)
            )
        )
    }

    /// The first paint samples, because it measures every column of the result before the grid can
    /// draw a single row.
    private static func automaticSampleRowCount(columnCount: Int) -> Int {
        columnCount > wideResultColumnCount ? wideResultSampleRowCount : sampleRowCount
    }

    /// An explicit fit reads the page rather than a sample, because a sample that stepped over the
    /// longest value is the reason the user asked twice. The budget is on the whole gesture, not on
    /// one column, so fitting a single column covers any page a user can configure while fitting
    /// every column of a wide result stays a bounded amount of formatting on the main thread.
    private static func fitSampleRowCount(fittedColumnCount: Int) -> Int {
        max(sampleRowCount, fitToContentValueBudget / max(1, fittedColumnCount))
    }

    private func measureColumnWidth(
        for columnName: String,
        columnIndex: Int,
        tableRows: TableRows,
        accessory: DataGridCellAccessory,
        displayFormat: ValueDisplayFormat?,
        databaseType: DatabaseType?,
        isLargeDataset: Bool,
        nullDisplayString: String?,
        budget: ColumnWidthBudget
    ) -> CGFloat {
        let charWidth = ThemeEngine.shared.dataGridFonts.monoCharWidth
        let headerCharCount = (columnName as NSString).length
        var maxWidth = CGFloat(headerCharCount) * charWidth * Self.headerCharWidthRatio + Self.headerPadding

        let totalRows = tableRows.count
        let step = max(1, totalRows / max(1, budget.sampledRows))

        let columnType = columnIndex < tableRows.columnTypes.count
            ? tableRows.columnTypes[columnIndex]
            : nil
        let resolvedNullDisplayString = nullDisplayString
            ?? AppSettingsManager.shared.dataGrid.nullDisplay

        for i in stride(from: 0, to: totalRows, by: step) {
            let rawValue = tableRows.value(at: i, column: columnIndex)
            let formattedValue = CellDisplayFormatter.format(
                rawValue,
                columnType: columnType,
                displayFormat: displayFormat,
                databaseType: databaseType
            ) ?? ""
            let value = DataGridCellContent.resolvedDisplayText(
                formattedValue,
                placeholder: DataGridCellContent.placeholder(for: rawValue),
                isLargeDataset: isLargeDataset,
                nullDisplayString: resolvedNullDisplayString
            )

            let charCount = min((value as NSString).length, budget.measuredCharLimit)
            maxWidth = max(maxWidth, CGFloat(charCount) * charWidth + accessory.measurementPadding)

            if maxWidth >= budget.cap {
                return budget.cap
            }
        }

        return min(max(maxWidth, Self.minColumnWidth), budget.cap)
    }
}

extension NSFont {
    func withTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

internal extension String {
    var containsLineBreak: Bool {
        let nsString = self as NSString
        let length = nsString.length
        guard length > 0 else { return false }
        for i in 0..<length {
            let ch = nsString.character(at: i)
            if ch == 0x0A || ch == 0x0D || ch == 0x0B || ch == 0x0C ||
               ch == 0x85 || ch == 0x2028 || ch == 0x2029 {
                return true
            }
        }
        return false
    }

    var sanitizedForCellDisplay: String {
        let nsString = self as NSString
        let length = nsString.length
        guard length > 0 else { return self }

        var mutable: NSMutableString?
        var copiedUpTo = 0
        for i in 0..<length {
            let ch = nsString.character(at: i)
            guard ch == 0x0A || ch == 0x0D || ch == 0x0B || ch == 0x0C ||
                  ch == 0x85 || ch == 0x2028 || ch == 0x2029 else { continue }

            if mutable == nil {
                mutable = NSMutableString(capacity: length)
            }
            if i > copiedUpTo {
                mutable?.append(nsString.substring(with: NSRange(location: copiedUpTo, length: i - copiedUpTo)))
            }
            mutable?.append(" ")
            copiedUpTo = i + 1
        }

        guard let result = mutable else { return self }
        if copiedUpTo < length {
            result.append(nsString.substring(with: NSRange(location: copiedUpTo, length: length - copiedUpTo)))
        }
        return result as String
    }
}
