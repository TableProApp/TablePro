//
//  TreeOutlineView.swift
//  TablePro
//

import AppKit

@MainActor
internal protocol TreeOutlineCommands: AnyObject {
    var canCopySelection: Bool { get }
    func copySelection()
    func openSelectedLink() -> Bool
    func fieldEditorMenu(forRow row: Int, hasTextSelection: Bool) -> NSMenu?
}

/// No `doubleAction`: with one set, `NSTableView` never lets the field editor start, so no value
/// text can be selected.
internal final class TreeOutlineView: SidebarOutlineView {
    internal weak var commands: (any TreeOutlineCommands)?

    private var responderObservation: NSKeyValueObservation?

    internal static func make() -> TreeOutlineView {
        let outlineView = TreeOutlineView()
        outlineView.headerView = nil
        outlineView.style = .inset
        outlineView.rowSizeStyle = .custom
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        outlineView.autosaveExpandedItems = false
        outlineView.setAccessibilityIdentifier("tree-outline")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TreeOutlineColumn"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        return outlineView
    }

    /// The field editor becomes first responder before its delegate, the text field, is set, so
    /// the row that holds it is only found one turn later.
    override internal func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        responderObservation = window?.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.reapplyRowEmphasis() }
            Task { @MainActor [weak self] in self?.reapplyRowEmphasis() }
        }
    }

    @objc internal func copy(_ sender: Any?) {
        commands?.copySelection()
    }

    /// A disabled Copy still owns Command-C, so it never falls through to the window's own Copy.
    override internal func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(copy(_:)) else { return super.validateUserInterfaceItem(item) }
        return commands?.canCopySelection ?? false
    }

    override internal func cancelOperation(_ sender: Any?) {
        guard !clearSelection() else { return }
        super.cancelOperation(sender)
    }

    /// A table passes an unused Escape up as a key, and a host's Cancel button takes it before any
    /// `cancelOperation(_:)` is sent, so the first Escape is caught here. Return stays with Save.
    override internal func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.isDisjoint(with: [.command, .option, .control, .shift]) {
            switch KeyCode(rawValue: event.keyCode) {
            case .escape:
                if clearSelection() { return }
            case .space:
                if commands?.openSelectedLink() == true { return }
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    private func clearSelection() -> Bool {
        guard !selectedRowIndexes.isEmpty else { return false }
        deselectAll(nil)
        return true
    }

    internal func fieldEditorMenu(for field: NSView, hasTextSelection: Bool) -> NSMenu? {
        commands?.fieldEditorMenu(forRow: row(for: field), hasTextSelection: hasTextSelection)
    }

    /// Rebuilding or hiding the row that holds the field editor would leave the window with no first
    /// responder.
    internal func reclaimKeyboardFromFieldEditor() {
        guard let window, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSView, field.isDescendant(of: self) else { return }
        window.makeFirstResponder(self)
    }

    private func reapplyRowEmphasis() {
        enumerateAvailableRowViews { rowView, _ in
            (rowView as? TreeOutlineRowView)?.reapplyEmphasis()
        }
    }
}

/// Unemphasized while its value holds a text selection, which is unreadable on the accent color.
internal class TreeOutlineRowView: NSTableRowView {
    internal class var reuseIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("TreeOutlineRow")
    }

    private var requestedEmphasis: Bool?

    /// In the setter, not the getter: a popover's selection material is configured only when the
    /// stored value changes. AppKit's own request is kept for when the text selection ends.
    override internal var isEmphasized: Bool {
        get { super.isEmphasized }
        set {
            requestedEmphasis = newValue
            super.isEmphasized = newValue && !hostsFieldEditor
        }
    }

    private var hostsFieldEditor: Bool {
        guard let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSView else { return false }
        return field.isDescendant(of: self)
    }

    /// AppKit restyles the cells only on its own writes.
    internal func reapplyEmphasis() {
        let resolved = (requestedEmphasis ?? super.isEmphasized) && !hostsFieldEditor
        if super.isEmphasized != resolved {
            super.isEmphasized = resolved
        }
        let style = interiorBackgroundStyle
        for case let cell as NSTableCellView in subviews where cell.backgroundStyle != style {
            cell.backgroundStyle = style
        }
    }
}

/// The tree row while the theme sets the outline's background or selection.
internal final class ThemedTreeOutlineRowView: TreeOutlineRowView, ThemeTableRowDrawing {
    override internal class var reuseIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("ThemedTreeOutlineRow")
    }

    internal weak var chrome: ThemeTableChrome?

    override internal func drawBackground(in dirtyRect: NSRect) {
        guard chrome?.drawBackground(of: self, in: dirtyRect) == true else {
            super.drawBackground(in: dirtyRect)
            return
        }
    }

    override internal func drawSelection(in dirtyRect: NSRect) {
        guard let chrome else {
            super.drawSelection(in: dirtyRect)
            return
        }
        chrome.drawSelection(of: self, in: dirtyRect) { super.drawSelection(in: $0) }
    }

    override internal var interiorBackgroundStyle: NSView.BackgroundStyle {
        let native = super.interiorBackgroundStyle
        return chrome?.interiorBackgroundStyle(of: self, native: native) ?? native
    }
}
