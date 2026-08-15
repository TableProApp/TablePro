//
//  FavoriteFolderRenameOverlayTests.swift
//  TableProTests
//

import AppKit
import Testing

@testable import TablePro

@Suite("Favorite folder rename overlay")
@MainActor
struct FavoriteFolderRenameOverlayTests {
    private final class SingleNodeSource: NSObject, NSOutlineViewDataSource {
        var isPresent = true

        private let node: FavoritesOutlineNode

        init(node: FavoritesOutlineNode) {
            self.node = node
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            item == nil && isPresent ? 1 : 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            node
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            false
        }
    }

    @MainActor
    private final class Harness {
        let overlay = FavoriteFolderRenameOverlay()
        let outlineView = NSOutlineView()
        let window: NSWindow
        let node: FavoritesOutlineNode
        let folder: SQLFavoriteFolder
        let source: SingleNodeSource

        init() {
            folder = SQLFavoriteFolder(name: "Reports")
            node = FavoritesOutlineNode(id: folder.id.uuidString, kind: .header("Reports"))
            source = SingleNodeSource(node: node)
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 240, height: 200),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
            outlineView.addTableColumn(column)
            outlineView.outlineTableColumn = column
            outlineView.dataSource = source
            window.contentView = outlineView
            outlineView.reloadData()
        }

        func editingField() throws -> NSTextField {
            try #require(outlineView.subviews.compactMap { $0 as? NSTextField }.first)
        }
    }

    @Test("Clicking away keeps the typed name")
    func endEditingCommitsTypedName() throws {
        let harness = Harness()
        var committed: (folder: SQLFavoriteFolder, name: String)?
        var cancelled = false
        harness.overlay.onCommit = { committed = (folder: $0, name: $1) }
        harness.overlay.onCancel = { cancelled = true }

        harness.overlay.begin(node: harness.node, folder: harness.folder, in: harness.outlineView)
        let field = try harness.editingField()
        field.stringValue = "Quarterly Reports"
        harness.overlay.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: field)
        )

        #expect(committed?.name == "Quarterly Reports")
        #expect(committed?.folder.id == harness.folder.id)
        #expect(cancelled == false)
        #expect(harness.overlay.isActive == false)
    }

    @Test("Escape discards the typed name")
    func escapeDiscardsTypedName() throws {
        let harness = Harness()
        var committed = false
        var cancelled = false
        harness.overlay.onCommit = { _, _ in committed = true }
        harness.overlay.onCancel = { cancelled = true }

        harness.overlay.begin(node: harness.node, folder: harness.folder, in: harness.outlineView)
        let field = try harness.editingField()
        field.stringValue = "Discarded"
        let handled = harness.overlay.control(
            field,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )

        #expect(handled)
        #expect(cancelled)
        #expect(committed == false)
        #expect(harness.overlay.isActive == false)
    }

    @Test("Return keeps the typed name")
    func returnCommitsTypedName() throws {
        let harness = Harness()
        var committed: String?
        harness.overlay.onCommit = { committed = $1 }

        harness.overlay.begin(node: harness.node, folder: harness.folder, in: harness.outlineView)
        let field = try harness.editingField()
        field.stringValue = "Monthly Reports"
        let handled = harness.overlay.control(
            field,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )

        #expect(handled)
        #expect(committed == "Monthly Reports")
        #expect(harness.overlay.isActive == false)
    }

    @Test("A row that disappeared during a reload discards the edit")
    func vanishedRowDiscardsEdit() throws {
        let harness = Harness()
        var committed = false
        var cancelled = false
        harness.overlay.onCommit = { _, _ in committed = true }
        harness.overlay.onCancel = { cancelled = true }

        harness.overlay.begin(node: harness.node, folder: harness.folder, in: harness.outlineView)
        let field = try harness.editingField()
        field.stringValue = "Never Saved"
        harness.source.isPresent = false
        harness.outlineView.reloadData()
        harness.overlay.reposition(in: harness.outlineView)

        #expect(cancelled)
        #expect(committed == false)
        #expect(harness.overlay.isActive == false)
    }
}
