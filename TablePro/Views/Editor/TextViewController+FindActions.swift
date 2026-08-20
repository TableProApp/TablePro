//
//  TextViewController+FindActions.swift
//  TablePro
//

import AppKit
import CodeEditSourceEditor

/// The Edit menu's Find items are nil-targeted, so AppKit resolves them through the responder chain.
/// `SourceEditor` is an `NSViewControllerRepresentable`, which makes `TextViewController` a child view
/// controller sitting between its own text view and the window's content view controller. Declaring the
/// selectors here is what lets the editor that actually holds first responder answer for itself, so a
/// find never has to be aimed at an editor found by scanning the key window. Any other focused surface
/// falls through to its own handler, and a window with no focused editor falls through to
/// `MainSplitViewController`, which disables the items it cannot service.
internal extension TextViewController {
    @objc func performFind(_ sender: Any?) {
        showFindPanel()
    }

    @objc func findNext(_ sender: Any?) {
        self.findNext()
    }

    @objc func findPrevious(_ sender: Any?) {
        self.findPrevious()
    }
}
