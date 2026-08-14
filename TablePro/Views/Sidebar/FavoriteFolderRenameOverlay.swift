//
//  FavoriteFolderRenameOverlay.swift
//  TablePro
//

import AppKit

/// Renaming a folder in place, as a field the coordinator owns and floats over the row rather than
/// one baked into the cell.
///
/// A cell is pooled and handed to whatever row needs it next, and the outline reloads whenever the
/// favorites change, including from another window. An edit session living inside a pooled cell can
/// be handed to a different row mid-edit; one that is never an outline item cannot.
@MainActor
internal final class FavoriteFolderRenameOverlay: NSObject, NSTextFieldDelegate {
    internal var onCommit: ((SQLFavoriteFolder, String) -> Void)?
    internal var onCancel: (() -> Void)?

    private var textField: NSTextField?
    private var folder: SQLFavoriteFolder?
    private var node: FavoritesOutlineNode?

    internal var isActive: Bool { textField != nil }

    internal func begin(node: FavoritesOutlineNode, folder: SQLFavoriteFolder, in outlineView: NSOutlineView) {
        dismiss(commit: false)
        let row = outlineView.row(forItem: node)
        guard row >= 0, let window = outlineView.window else { return }
        let field = NSTextField(frame: outlineView.frameOfCell(atColumn: 0, row: row))
        field.stringValue = folder.name
        field.delegate = self
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        outlineView.addSubview(field)
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        textField = field
        self.folder = folder
        self.node = node
    }

    /// A reload can move the row under the field, or remove it. The field is a subview of the
    /// outline, so scrolling carries it, but a row that shifted leaves it painted over a neighbour
    /// the user is not editing.
    internal func reposition(in outlineView: NSOutlineView) {
        guard let textField, let node else { return }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else {
            dismiss(commit: false)
            return
        }
        textField.frame = outlineView.frameOfCell(atColumn: 0, row: row)
    }

    internal func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            dismiss(commit: true, restoringFocusTo: control.superview as? NSOutlineView)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss(commit: false, restoringFocusTo: control.superview as? NSOutlineView)
            return true
        }
        return false
    }

    /// Clicking away commits, the way Finder and the Xcode navigator do. Escape is the only way to
    /// discard. The focus already belongs to whatever was clicked, so nothing is restored.
    internal func controlTextDidEndEditing(_ notification: Notification) {
        dismiss(commit: true)
    }

    internal func dismiss(commit: Bool, restoringFocusTo outlineView: NSOutlineView? = nil) {
        guard let textField, let folder else { return }
        let value = textField.stringValue
        textField.delegate = nil
        textField.removeFromSuperview()
        self.textField = nil
        self.folder = nil
        node = nil
        if let outlineView {
            outlineView.window?.makeFirstResponder(outlineView)
        }
        if commit {
            onCommit?(folder, value)
        } else {
            onCancel?()
        }
    }
}
