//
//  SortableHeaderEmphasisTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@Suite("Sortable header emphasis")
@MainActor
struct SortableHeaderEmphasisTests {
    @Test("Emphasis needs both the key window and table focus")
    func requiresBothConditions() {
        #expect(SortableHeaderEmphasis.isEmphasized(tableViewHoldsFocus: true, isKeyWindow: true))
        #expect(SortableHeaderEmphasis.isEmphasized(tableViewHoldsFocus: true, isKeyWindow: false) == false)
        #expect(SortableHeaderEmphasis.isEmphasized(tableViewHoldsFocus: false, isKeyWindow: true) == false)
        #expect(SortableHeaderEmphasis.isEmphasized(tableViewHoldsFocus: false, isKeyWindow: false) == false)
    }

    /// An `NSTableView` with no columns answers `acceptsFirstResponder` with false, so a bare one
    /// would leave the window itself as the responder and the test would prove nothing.
    private func makeWindow() -> (NSWindow, NSTableView) {
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("column")))
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        scrollView.documentView = table
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(scrollView)
        return (window, table)
    }

    @Test("The table itself holding focus counts")
    func tableIsFirstResponder() {
        let (window, table) = makeWindow()
        _ = window.makeFirstResponder(table)
        #expect(SortableHeaderEmphasis.holdsFocus(tableView: table, in: window))
    }

    /// A cell edit installs the field editor below the table, so focus has to be resolved by
    /// ancestry. Keying on identity alone dropped the header out of emphasis mid-edit.
    @Test("A responder inside the table still counts as focus")
    func descendantIsFirstResponder() {
        let (window, table) = makeWindow()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
        table.addSubview(field)
        _ = window.makeFirstResponder(field)
        #expect(SortableHeaderEmphasis.holdsFocus(tableView: table, in: window))
    }

    @Test("A responder outside the table does not count as focus")
    func siblingIsFirstResponder() {
        let (window, table) = makeWindow()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
        window.contentView?.addSubview(field)
        _ = window.makeFirstResponder(field)
        #expect(SortableHeaderEmphasis.holdsFocus(tableView: table, in: window) == false)
    }

    @Test("No table and no window resolve to no focus")
    func missingPiecesResolveToFalse() {
        let (window, table) = makeWindow()
        #expect(SortableHeaderEmphasis.holdsFocus(tableView: nil, in: window) == false)
        #expect(SortableHeaderEmphasis.holdsFocus(tableView: table, in: nil) == false)
    }
}
