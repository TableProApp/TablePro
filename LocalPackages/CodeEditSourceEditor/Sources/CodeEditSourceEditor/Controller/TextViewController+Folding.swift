//
//  TextViewController+Folding.swift
//  CodeEditSourceEditor
//

import AppKit

public extension TextViewController {
    /// Posted on the controller whenever a fold collapses or expands.
    static let foldStateDidChangeNotification = Notification.Name(
        "CodeEditSourceEditor.foldStateDidChangeNotification"
    )

    /// The range of every fold in the document, collapsed or not, ordered by start position.
    var foldRanges: [Range<Int>] {
        foldModel?.getFolds(in: textView.documentRange.intRange).map(\.range) ?? []
    }

    /// The ranges of every collapsed fold, suitable for persisting and replaying with ``restoreCollapsedFolds(_:)``.
    var collapsedFoldRanges: [Range<Int>] {
        foldModel?.collapsedFoldRanges() ?? []
    }

    /// Collapses the outermost folds in the document.
    func foldAll() {
        foldModel?.setAllCollapsed(true)
    }

    /// Expands every collapsed fold in the document.
    func unfoldAll() {
        foldModel?.setAllCollapsed(false)
    }

    /// Collapses the fold at a line, or expands it when it is already collapsed.
    /// - Parameter lineNumber: The line to toggle, zero-indexed.
    /// - Returns: Whether a fold was found at that line.
    @discardableResult
    func toggleFold(atLine lineNumber: Int) -> Bool {
        guard let model = foldModel, let fold = model.getCachedFoldAt(lineNumber: lineNumber) else { return false }
        model.setCollapsed(!model.isCollapsed(fold), for: fold)
        return true
    }

    /// Toggles the innermost fold containing the cursor.
    /// - Returns: Whether a fold was found at the cursor.
    @discardableResult
    func toggleFoldAtCursor() -> Bool {
        guard let offset = cursorPositions.first?.range.location,
              let line = textView.layoutManager.textLineForOffset(offset) else { return false }
        return toggleFold(atLine: line.index)
    }

    /// Whether a fold containing the cursor is currently collapsed. `nil` when there is no fold at the cursor.
    func foldStateAtCursor() -> Bool? {
        guard let model = foldModel,
              let offset = cursorPositions.first?.range.location,
              let line = textView.layoutManager.textLineForOffset(offset),
              let fold = model.getCachedFoldAt(lineNumber: line.index) else { return nil }
        return model.isCollapsed(fold)
    }

    /// Collapses the folds matching the given ranges once they have been calculated.
    ///
    /// Ranges that no longer match a fold are dropped, so a document edited outside the editor restores what it can
    /// instead of failing.
    func restoreCollapsedFolds(_ ranges: [Range<Int>]) {
        foldModel?.restoreCollapsedFolds(ranges)
    }

    internal var foldModel: LineFoldModel? {
        gutterView?.foldingRibbon.model
    }
}
