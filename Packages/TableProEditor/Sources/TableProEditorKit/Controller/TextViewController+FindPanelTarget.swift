//
//  TextViewController+FindPanelTarget.swift
//  TableProEditorKit
//
//  Created by Khan Winter on 3/16/25.
//

import AppKit
import TableProTextEngine

extension TextViewController: FindPanelTarget {
    var findPanelTargetView: NSView {
        textView
    }

    func findPanelWillShow(panelHeight: CGFloat) {
        updateContentInsets()
    }

    func findPanelWillHide(panelHeight: CGFloat) {
        updateContentInsets()
    }

    func findPanelModeDidChange(to mode: FindPanelMode) {
        updateContentInsets()
    }

    var emphasisManager: EmphasisManager? {
        textView?.emphasisManager
    }

    var isFindReplaceEditable: Bool {
        textView?.isEditable ?? false
    }

    /// One undo group per call, so a Replace never merges into the typing before it or into the next Replace. Each
    /// match is its own range in one edit, so the selection, a collapsed fold and the undo history all move with the
    /// text between matches. The edit skips the typing filters, which would wrap a pair or delete an indent.
    func replaceFindMatches(_ replacements: [TextReplacement]) -> Bool {
        guard let textView, textView.isEditable, !replacements.isEmpty else { return false }
        let length = (textView.string as NSString).length
        guard replacements.allSatisfy({ NSMaxRange($0.range) <= length }) else { return false }

        textView.undoManager?.beginUndoGrouping()
        isApplyingUnfilteredEdits = true
        textView.replaceCharacters(replacements)
        isApplyingUnfilteredEdits = false
        textView.undoManager?.endUndoGrouping()
        return true
    }
}

public extension TextViewController {
    func showFindPanel() {
        _ = textView.resignFirstResponder()
        findViewController?.showFindPanel()
    }

    func showFindAndReplacePanel() {
        _ = textView.resignFirstResponder()
        findViewController?.showFindPanel(mode: .replace)
    }

    func findNext() {
        findViewController?.viewModel.moveToNextMatch()
    }

    func findPrevious() {
        findViewController?.viewModel.moveToPreviousMatch()
    }

    /// Whether there is a selection that `useSelectionForFind()` would search for.
    var hasSelectionForFind: Bool {
        selectedTextForFind != nil
    }

    /// Make the selected text the search term, without opening the panel and without moving the caret.
    ///
    /// This is the Edit menu's Use Selection for Find, and it matches what macOS does: the panel stays shut,
    /// the selection stays where it is, and the next Find Next is what walks to the following match.
    func useSelectionForFind() {
        guard let selection = selectedTextForFind, let viewModel = findViewController?.viewModel else { return }
        viewModel.findText = selection
        viewModel.find()
    }

    private var selectedTextForFind: String? {
        guard let range = cursorPositions.first?.range, !range.isEmpty else { return nil }
        let text = (textView.string as NSString).substring(with: range)
        return text.isEmpty ? nil : text
    }
}
