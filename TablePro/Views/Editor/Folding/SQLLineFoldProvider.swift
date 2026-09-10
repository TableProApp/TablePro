//
//  SQLLineFoldProvider.swift
//  TablePro
//

import CodeEditSourceEditor
import CodeEditTextView
import Foundation
import TableProPluginKit

/// Answers the editor's per-line fold queries from a whole-document scan.
///
/// The editor restarts its walk at line zero every time the document changes, so the scan is refreshed there and every
/// other line is a dictionary lookup. That keeps the main-thread cost of a pass linear in the document, not quadratic.
final class SQLLineFoldProvider: LineFoldProvider {
    var dialect: SqlDialect

    private var structure: SQLFoldStructure = .empty
    private var scannedLength: Int = -1

    init(dialect: SqlDialect = .generic) {
        self.dialect = dialect
    }

    func foldLevelAtLine(
        lineNumber: Int,
        lineRange: NSRange,
        previousDepth: Int,
        controller: TextViewController
    ) -> [LineFoldProviderLineInfo] {
        guard let text = controller.textView.textStorage?.string as NSString? else { return [] }
        guard text.length <= controller.configuration.peripherals.foldingSizeLimit else { return [] }

        if lineNumber == 0 || scannedLength != text.length {
            structure = SQLFoldScanner.scan(text, dialect: dialect)
            scannedLength = text.length
        }

        var info: [LineFoldProviderLineInfo] = []
        for region in structure.endsByLine[lineNumber] ?? [] {
            info.append(.endFold(rangeEnd: region.range.upperBound, newDepth: region.depth - 1))
        }
        for region in structure.startsByLine[lineNumber] ?? [] {
            info.append(.startFold(rangeStart: region.range.lowerBound, newDepth: region.depth))
        }
        return info
    }

    func foldPlaceholderLabel(for summary: FoldPlaceholderSummary) -> String {
        guard summary.hiddenLineCount > 0 else { return summary.previewText }
        guard !summary.previewText.isEmpty else {
            return String(format: String(localized: "%d lines"), summary.hiddenLineCount)
        }
        return String(
            format: String(localized: "%1$@ … %2$d lines"),
            summary.previewText,
            summary.hiddenLineCount
        )
    }
}
