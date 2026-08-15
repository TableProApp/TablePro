//
//  FavoritesOutlineCellView.swift
//  TablePro
//

import AppKit
import SwiftUI

/// Hosts one SwiftUI row, and owns the field that renames it.
///
/// No emphasis is threaded through: AppKit publishes `backgroundStyle` into the hosted view's
/// environment as `backgroundProminence`, which is what the row content already reads.
///
/// The rename field is a real subview assigned to `NSTableCellView.textField`, so `NSOutlineView`
/// lays it out through every expand, collapse, scroll and row-height change, and AppKit treats a
/// cell with an edit in progress as in use rather than recycling it. The overlay this replaced was
/// a bare field added to the outline view, positioned by hand from one call site, which left it
/// painted over a neighbouring row after any disclosure change.
internal final class FavoritesOutlineCellView<Row: View>: NSTableCellView {
    private var hosting: NSHostingView<Row>?
    private var editorField: NSTextField?
    private var editorIcon: NSImageView?

    internal private(set) var isRenaming = false

    internal func update(rootView: Row) {
        if let hosting {
            hosting.rootView = rootView
            /// A reload during an edit must not put the row's label back over the field.
            hosting.isHidden = isRenaming
            return
        }
        let view = NSHostingView(rootView: rootView)
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        hosting = view
    }

    internal func beginRename(text: String, delegate: any NSTextFieldDelegate) {
        let field = makeEditorIfNeeded()
        field.stringValue = text
        field.delegate = delegate
        field.isHidden = false
        editorIcon?.isHidden = false
        hosting?.isHidden = true
        isRenaming = true
    }

    @discardableResult
    internal func endRename() -> String {
        guard let field = editorField else { return "" }
        let value = field.stringValue
        field.delegate = nil
        field.isHidden = true
        editorIcon?.isHidden = true
        hosting?.isHidden = false
        isRenaming = false
        return value
    }

    internal var editor: NSTextField? { editorField }

    private func makeEditorIfNeeded() -> NSTextField {
        if let editorField { return editorField }

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
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
        field.setAccessibilityIdentifier("favorites-rename-field")
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
