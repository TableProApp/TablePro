//
//  DataGridCellFactory.swift
//  TablePro
//

import AppKit
import Foundation

@MainActor
final class DataGridCellFactory {
    private static let minColumnWidth: CGFloat = 60
    private static let maxColumnWidth: CGFloat = 800
    private static let sampleRowCount = 30
    private static let maxMeasureChars = 50

    private static let headerFont: NSFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

    func calculateColumnWidth(for columnName: String) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.headerFont]
        let size = (columnName as NSString).size(withAttributes: attributes)
        let width = size.width + 48
        return min(max(width, Self.minColumnWidth), Self.maxColumnWidth)
    }

    func calculateOptimalColumnWidth(
        for columnName: String,
        columnIndex: Int,
        tableRows: TableRows
    ) -> CGFloat {
        let headerCharCount = (columnName as NSString).length
        var maxWidth = CGFloat(headerCharCount) * ThemeEngine.shared.dataGridFonts.monoCharWidth * 0.75 + 48

        let totalRows = tableRows.count
        let columnCount = tableRows.columns.count
        let effectiveSampleCount = columnCount > 50 ? 10 : Self.sampleRowCount
        let step = max(1, totalRows / effectiveSampleCount)
        let charWidth = ThemeEngine.shared.dataGridFonts.monoCharWidth

        for i in stride(from: 0, to: totalRows, by: step) {
            guard let value = tableRows.value(at: i, column: columnIndex) else { continue }

            let charCount = min((value as NSString).length, Self.maxMeasureChars)
            let cellWidth = CGFloat(charCount) * charWidth + 16
            maxWidth = max(maxWidth, cellWidth)

            if maxWidth >= Self.maxColumnWidth {
                return Self.maxColumnWidth
            }
        }

        return min(max(maxWidth, Self.minColumnWidth), Self.maxColumnWidth)
    }

    func calculateFitToContentWidth(
        for columnName: String,
        columnIndex: Int,
        tableRows: TableRows
    ) -> CGFloat {
        let headerCharCount = (columnName as NSString).length
        var maxWidth = CGFloat(headerCharCount) * ThemeEngine.shared.dataGridFonts.monoCharWidth * 0.75 + 48

        let totalRows = tableRows.count
        let columnCount = tableRows.columns.count
        let effectiveSampleCount = columnCount > 50 ? 10 : Self.sampleRowCount
        let step = max(1, totalRows / effectiveSampleCount)
        let charWidth = ThemeEngine.shared.dataGridFonts.monoCharWidth

        for i in stride(from: 0, to: totalRows, by: step) {
            guard let value = tableRows.value(at: i, column: columnIndex) else { continue }

            let charCount = (value as NSString).length
            let cellWidth = CGFloat(charCount) * charWidth + 16
            maxWidth = max(maxWidth, cellWidth)
        }

        return max(maxWidth, Self.minColumnWidth)
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
