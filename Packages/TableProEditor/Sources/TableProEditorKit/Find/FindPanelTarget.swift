//
//  FindPanelTarget.swift
//  TableProEditorKit
//
//  Created by Khan Winter on 3/10/25.
//

import AppKit
import TableProTextEngine

protocol FindPanelTarget: AnyObject {
    var textView: TextView! { get }
    var findPanelTargetView: NSView { get }

    var cursorPositions: [CursorPosition] { get }
    func setCursorPositions(_ positions: [CursorPosition], scrollToVisible: Bool)
    func updateCursorPosition()

    /// Whether the document can be edited, which Replace and All need.
    var isFindReplaceEditable: Bool { get }

    /// Applies the replacements to the current document as one undoable edit.
    /// - Returns: `false` when nothing was replaced.
    func replaceFindMatches(_ replacements: [TextReplacement]) -> Bool

    func findPanelWillShow(panelHeight: CGFloat)
    func findPanelWillHide(panelHeight: CGFloat)
    func findPanelModeDidChange(to mode: FindPanelMode)
}
