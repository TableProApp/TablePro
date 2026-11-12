//
//  RenamableSidebarCellView.swift
//  TablePro
//

import AppKit
import SwiftUI

/// A source list cell whose label can be edited in place.
///
/// The rename field is a real subview assigned to `NSTableCellView.textField`, so `NSOutlineView`
/// lays it out through every expand, collapse, scroll and row-height change, and AppKit treats a
/// cell with an edit in progress as in use rather than recycling it. The overlay this replaced was
/// a bare field added to the outline view, positioned by hand from one call site, which left it
/// painted over a neighbouring row after any disclosure change.
///
/// The icon and the accessibility identifier are the subclass's, because the two lists that use
/// this have neither in common: Favorites edits folders and nothing else, while the object tree
/// edits tables, views and schemas, each with its own glyph.
internal class RenamableSidebarCellView<Row: View>: SidebarHostingCellView<Row> {
    private var editorField: NSTextField?
    private var editorIcon: NSImageView?

    internal private(set) var isRenaming = false

    /// Overridden by a cell that draws more than one kind of row.
    internal var editorSymbolName: String { "folder" }
    internal var editorAccessibilityIdentifier: String { "sidebar-rename-field" }

    internal func beginRename(text: String, delegate: any NSTextFieldDelegate) {
        let field = makeEditorIfNeeded()
        editorIcon?.image = NSImage(systemSymbolName: editorSymbolName, accessibilityDescription: nil)
        field.stringValue = text
        field.delegate = delegate
        isRenaming = true
        applyContentVisibility()
    }

    @discardableResult
    internal func endRename() -> String {
        guard let field = editorField else { return "" }
        let value = field.stringValue
        field.delegate = nil
        isRenaming = false
        applyContentVisibility()
        return value
    }

    internal var editor: NSTextField? { editorField }

    /// A reload during an edit calls `update(rootView:)` on every visible cell, so the row's own
    /// label must not come back over the field the user is typing in.
    override internal func applyContentVisibility() {
        setHostedContentHidden(isRenaming)
        editorField?.isHidden = !isRenaming
        editorIcon?.isHidden = !isRenaming
    }

    private func makeEditorIfNeeded() -> NSTextField {
        if let editorField { return editorField }

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: editorSymbolName, accessibilityDescription: nil)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.isHidden = true
        addSubview(icon)

        let field = NSTextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isBezeled = false
        field.drawsBackground = true
        field.isEditable = true
        field.isSelectable = true
        field.focusRingType = .default
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        (field.cell as? NSTextFieldCell)?.isScrollable = true
        field.isHidden = true
        field.setAccessibilityIdentifier(editorAccessibilityIdentifier)
        addSubview(field)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        /// The inherited outlets are what make AppKit colour the field for a selected row and hand
        /// it to VoiceOver, so they are set rather than kept as private references.
        imageView = icon
        textField = field
        editorIcon = icon
        editorField = field
        return field
    }
}
