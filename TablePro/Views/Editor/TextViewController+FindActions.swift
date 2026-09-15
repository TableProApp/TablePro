//
//  TextViewController+FindActions.swift
//  TablePro
//

import AppKit
import TableProEditorKit

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

    @objc func performFindAndReplace(_ sender: Any?) {
        showFindAndReplacePanel()
    }

    @objc func findNext(_ sender: Any?) {
        self.findNext()
    }

    @objc func findPrevious(_ sender: Any?) {
        self.findPrevious()
    }

    @objc func useSelectionForFind(_ sender: Any?) {
        self.useSelectionForFind()
    }
}

/// AppKit enables a nil-targeted item as soon as something in the chain responds to its action, so
/// Use Selection for Find would read as available over an empty caret. The focused editor is the only
/// responder that knows whether there is a selection, and it is the one AppKit asks: validation stops at
/// the target it resolved, so `MainSplitViewController` never gets to answer for a focused editor.
///
/// The conformance is retroactive because the app owns neither side of it. If `TableProEditorKit` ever
/// declares it, delete this and move the switch there.
extension TextViewController: @retroactive NSMenuItemValidation {
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(useSelectionForFind(_:)):
            return hasSelectionForFind
        default:
            return true
        }
    }
}
