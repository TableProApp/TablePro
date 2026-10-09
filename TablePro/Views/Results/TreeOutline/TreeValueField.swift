//
//  TreeValueField.swift
//  TablePro
//

import AppKit

/// `NSTableView` gives a text field the mouse only in a selected row, so a first click selects the
/// row. The field editor's delegate is the text field, which is why it implements these methods.
internal final class TreeValueField: NSTextField, NSTextViewDelegate {
    internal var linkURL: URL?
    internal var linkRange: NSRange?

    override internal func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome { markLinkInFieldEditor() }
        return didBecome
    }

    /// The row's own text has no `.link` run, see `TreeValueStyle`.
    internal func markLinkInFieldEditor() {
        guard let linkURL, let linkRange, let storage = (currentEditor() as? NSTextView)?.textStorage,
              NSMaxRange(linkRange) <= storage.length else { return }
        storage.addAttribute(.link, value: linkURL, range: linkRange)
    }

    /// A click that selects no text would leave an invisible caret holding the keyboard, and Copy
    /// would copy nothing.
    override internal func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard let editor = currentEditor(), editor.selectedRange.length == 0,
              let outline = enclosingTreeOutline else { return }
        window?.makeFirstResponder(outline)
    }

    /// Returning true stops AppKit from opening the URL itself, outside the policy.
    internal func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let linkURL {
            DataLinkPolicy.open(linkURL)
        }
        return true
    }

    internal func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        let hasTextSelection = view.selectedRange().length > 0
        return enclosingTreeOutline?.fieldEditorMenu(for: self, hasTextSelection: hasTextSelection) ?? menu
    }

    private var enclosingTreeOutline: TreeOutlineView? {
        var ancestor = superview
        while let view = ancestor {
            if let outline = view as? TreeOutlineView { return outline }
            ancestor = view.superview
        }
        return nil
    }
}
