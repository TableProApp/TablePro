//
//  CellTextField.swift
//  TablePro
//
//  Custom text field that delegates context menu to row view.
//  Extracted from DataGridView for better maintainability.
//

import AppKit

/// NSTextField subclass that shows row context menu instead of text editing menu
final class CellTextField: NSTextField {
    /// The original (non-truncated) value for editing
    var originalValue: String?

    /// The truncated display value
    private var truncatedValue: String?

    override var stringValue: String {
        didSet {
            // Store the truncated value when set externally
            truncatedValue = stringValue
        }
    }

    override func becomeFirstResponder() -> Bool {
        if let original = originalValue {
            super.stringValue = original
        }
        return super.becomeFirstResponder()
    }

    /// Call this when editing ends to restore truncated display
    func restoreTruncatedDisplay() {
        if let truncated = truncatedValue {
            super.stringValue = truncated
        }
    }

    /// Override right mouse down to end editing and show row context menu
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(nil)

        var view: NSView? = self
        while let parent = view?.superview {
            if let rowView = parent as? TableRowViewWithMenu {
                if let menu = rowView.menu(for: event) {
                    NSMenu.popUpContextMenu(menu, with: event, for: self)
                }
                return
            }
            view = parent
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(nil)

        var view: NSView? = self
        while let parent = view?.superview {
            if let rowView = parent as? TableRowViewWithMenu {
                return rowView.menu(for: event)
            }
            view = parent
        }

        return nil
    }
}

final class DataGridFieldEditor: NSTextView {
    private static let menuKeyEquivalents: Set<String> = ["s"]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           let chars = event.charactersIgnoringModifiers,
           Self.menuKeyEquivalents.contains(chars) {
            window?.makeFirstResponder(nil)
            return false
        }
        return super.performKeyEquivalent(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(nil)

        var view: NSView? = self
        while let parent = view?.superview {
            if let cellTextField = parent as? CellTextField {
                cellTextField.rightMouseDown(with: event)
                return
            }
            view = parent
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        nil
    }
}
