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
    private static let maxMeasureChars = 50
    private static let headerPadding: CGFloat = 48
    private static let cellPadding: CGFloat = 16
    private static let headerCharWidthRatio: CGFloat = 0.75

    static func fitToContentCap(availableWidth: CGFloat) -> CGFloat {
        let proportional = availableWidth * fitToContentViewportFraction
        return min(max(proportional, minFitToContentWidth), maxColumnWidth)
    }

    func calculateOptimalColumnWidth(
        for columnName: String,
        columnIndex: Int,
        tableRows: TableRows
    ) -> CGFloat {
        measureColumnWidth(
            for: columnName,
            columnIndex: columnIndex,
            tableRows: tableRows,
            cap: Self.maxColumnWidth,
            measuredCharLimit: Self.maxMeasureChars
        )
    }

    func calculateFitToContentWidth(
        for columnName: String,
        columnIndex: Int,
        tableRows: TableRows,
        availableWidth: CGFloat
    ) -> CGFloat {
        let cap = Self.fitToContentCap(availableWidth: availableWidth)
        let charWidth = ThemeEngine.shared.dataGridFonts.monoCharWidth
        let measuredCharLimit = charWidth > 0 ? Int((cap / charWidth).rounded(.up)) : Self.maxMeasureChars

        return measureColumnWidth(
            for: columnName,
            columnIndex: columnIndex,
            tableRows: tableRows,
            cap: cap,
            measuredCharLimit: measuredCharLimit
        )
    }

    private func measureColumnWidth(
        for columnName: String,
        columnIndex: Int,
        tableRows: TableRows,
        cap: CGFloat,
        measuredCharLimit: Int
    ) -> CGFloat {
        let charWidth = ThemeEngine.shared.dataGridFonts.monoCharWidth
        let headerCharCount = (columnName as NSString).length
        var maxWidth = CGFloat(headerCharCount) * charWidth * Self.headerCharWidthRatio + Self.headerPadding

        let totalRows = tableRows.count
        let effectiveSampleCount = tableRows.columns.count > 50 ? 10 : Self.sampleRowCount
        let step = max(1, totalRows / effectiveSampleCount)

        for i in stride(from: 0, to: totalRows, by: step) {
            guard let value = tableRows.value(at: i, column: columnIndex).asText else { continue }

            let charCount = min((value as NSString).length, measuredCharLimit)
            maxWidth = max(maxWidth, CGFloat(charCount) * charWidth + Self.cellPadding)

            if maxWidth >= cap {
                return cap
            }
        }

        return min(max(maxWidth, Self.minColumnWidth), cap)
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
