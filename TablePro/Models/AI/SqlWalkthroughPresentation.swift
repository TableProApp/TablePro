//
//  SqlWalkthroughPresentation.swift
//  TablePro
//

import Foundation

/// Diff geometry for one walkthrough block, computed once and cached by the view.
/// Building this inside a SwiftUI body would re-run the line diff on every state
/// change, including each keystroke in a follow-up field.
struct SqlWalkthroughPresentation: Equatable, Sendable {
    /// Caps the work the line diff can be asked to do. A query pasted from a dump can
    /// be enormous, and the diff cost grows with the input, not with what is displayed.
    static let maxInputLines = 2_000
    static let maxDisplayedLines = 500

    let beforeLines: [String]
    let afterLines: [String]
    let droppedInputLines: Int

    let unifiedLines: [DiffUnifiedLine]
    let hiddenUnifiedLines: Int

    let splitPairs: [DiffPair]
    let hiddenSplitPairs: Int

    let sourceLines: [String]
    let hiddenSourceLines: Int

    init(beforeSQL: String, afterSQL: String?) {
        let allBefore = SqlNormalizer.lines(beforeSQL)
        let allAfter = afterSQL.map(SqlNormalizer.lines) ?? []

        let before = Array(allBefore.prefix(Self.maxInputLines))
        let after = Array(allAfter.prefix(Self.maxInputLines))
        beforeLines = before
        afterLines = after
        droppedInputLines = (allBefore.count - before.count) + (allAfter.count - after.count)

        let pairs = afterSQL == nil ? [] : DiffComputer.computeSplit(before: before, after: after)
        let unified = DiffComputer.computeUnified(from: pairs)

        splitPairs = Array(pairs.prefix(Self.maxDisplayedLines))
        hiddenSplitPairs = pairs.count - min(pairs.count, Self.maxDisplayedLines)

        unifiedLines = Array(unified.prefix(Self.maxDisplayedLines))
        hiddenUnifiedLines = unified.count - min(unified.count, Self.maxDisplayedLines)

        sourceLines = Array(before.prefix(Self.maxDisplayedLines))
        hiddenSourceLines = before.count - min(before.count, Self.maxDisplayedLines)
    }

    init(block: SqlWalkthroughBlock) {
        self.init(beforeSQL: block.beforeSQL, afterSQL: block.envelope.afterSQL)
    }

    func hiddenLines(for style: SqlWalkthroughDiffStyle) -> Int {
        switch style {
        case .unified: return hiddenUnifiedLines + droppedInputLines
        case .split: return hiddenSplitPairs + droppedInputLines
        }
    }

    var hiddenSourceListingLines: Int {
        hiddenSourceLines + droppedInputLines
    }

    func anchoredSnippet(for anchor: SqlWalkthroughAnchor) -> String? {
        let source = anchor.side == .after ? afterLines : beforeLines
        guard anchor.startLine >= 1, anchor.endLine >= anchor.startLine, anchor.endLine <= source.count else {
            return nil
        }
        let joined = source[(anchor.startLine - 1)..<anchor.endLine].joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    func resolvedAnchor(_ anchor: SqlWalkthroughAnchor?) -> SqlWalkthroughAnchor? {
        guard let anchor,
              anchor.isValid(beforeLineCount: beforeLines.count, afterLineCount: afterLines.count)
        else { return nil }
        return anchor
    }
}
