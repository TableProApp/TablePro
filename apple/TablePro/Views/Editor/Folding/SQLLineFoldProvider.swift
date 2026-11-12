import Foundation
import TableProEditorKit
import TableProSQLGrammar
import TableProTextEngine
import TableProUtilities

// The editor runs `documentFoldScanner()` off the main thread on a copy of the text. The per-line answers below are
// for callers that ask a line at a time; they rescan at line zero, so a pass stays linear in the document.
final class SQLLineFoldProvider: LineFoldProvider {
    var grammar: SQLLexicalGrammar

    private var structure: SQLFoldStructure = .empty
    private var scannedLength: Int = -1

    init(grammar: SQLLexicalGrammar = .ansi) {
        self.grammar = grammar
    }

    func documentFoldScanner() -> LineFoldDocumentScanner? {
        let grammar = grammar
        return { text in
            SQLFoldScanner.scan(text as NSString, grammar: grammar).regions.map {
                LineFoldProviderFold(depth: $0.depth, range: $0.range)
            }
        }
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
            structure = SQLFoldScanner.scan(text, grammar: grammar)
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
