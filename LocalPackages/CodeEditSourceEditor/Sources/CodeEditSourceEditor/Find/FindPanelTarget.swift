//
//  FindPanelTarget.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 3/10/25.
//

import AppKit
import CodeEditTextView

protocol FindPanelTarget: AnyObject {
    var textView: TextView! { get }
    var findPanelTargetView: NSView { get }

    var cursorPositions: [CursorPosition] { get }
    func setCursorPositions(_ positions: [CursorPosition], scrollToVisible: Bool)
    func updateCursorPosition()

    func findPanelWillShow(panelHeight: CGFloat)
    func findPanelWillHide(panelHeight: CGFloat)
    func findPanelModeDidChange(to mode: FindPanelMode)
}
