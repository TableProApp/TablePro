//
//  SidebarOutlineViewFocusTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

// A list that took the window's vacancy inside its own move into the window drew every row grey until the window's
// key state changed, because NSTableView does not observe the first responder during that move. The headless host
// cannot read emphasis, so these pin the timing and the conditions of the adoption.
@MainActor
struct SidebarOutlineViewFocusTests {
    private static let frame = NSRect(x: 0, y: 0, width: 600, height: 400)

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: Self.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: Self.frame)
        return window
    }

    // NSTableView refuses first responder while it has no column.
    private func makeList() -> SidebarOutlineView {
        let list = SidebarOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("column"))
        list.addTableColumn(column)
        list.outlineTableColumn = column
        return list
    }

    // The adoption is queued on the main queue as the list joins the window, so this runs after it.
    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func tearDown(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
    }

    @Test("A list joining a window nobody holds takes the keyboard after the move, not during it")
    func adoptsAfterTheMove() async throws {
        let window = makeWindow()
        defer { tearDown(window) }
        let list = makeList()

        try #require(window.firstResponder === window)
        window.contentView?.addSubview(list)
        #expect(window.firstResponder === window)

        await nextMainQueueTurn()
        #expect(window.firstResponder === list)
    }

    @Test("A view that takes the keyboard before the list's turn keeps it")
    func leavesAnEarlierClaimAlone() async {
        let window = makeWindow()
        defer { tearDown(window) }
        let field = NSTextField(frame: NSRect(x: 300, y: 300, width: 200, height: 22))
        window.contentView?.addSubview(field)

        window.contentView?.addSubview(makeList())
        #expect(window.makeFirstResponder(field))

        await nextMainQueueTurn()
        #expect(field.currentEditor() != nil)
    }

    @Test("A list in a collapsed pane never takes the keyboard")
    func hiddenListDoesNotAdopt() async {
        let window = makeWindow()
        defer { tearDown(window) }
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        pane.isHidden = true
        window.contentView?.addSubview(pane)

        pane.addSubview(makeList())

        await nextMainQueueTurn()
        #expect(window.firstResponder === window)
    }

    @Test("A list taken out of the window before its turn leaves the window alone")
    func removedListDoesNotAdopt() async {
        let window = makeWindow()
        defer { tearDown(window) }
        let list = makeList()

        window.contentView?.addSubview(list)
        list.removeFromSuperview()

        await nextMainQueueTurn()
        #expect(window.firstResponder === window)
    }

    // A connection switch swaps the sidebar first and the detail second, so the incoming list joined while the
    // outgoing editor still held the keyboard. With no incoming editor or grid built yet, the window was left empty.
    @Test("A list that joins while another view holds the keyboard takes it when that view leaves in the same turn")
    func takesTheKeyboardTheOutgoingViewDropped() async {
        let window = makeWindow()
        defer { tearDown(window) }
        let editor = NSTextView(frame: NSRect(x: 200, y: 0, width: 400, height: 400))
        window.contentView?.addSubview(editor)
        #expect(window.makeFirstResponder(editor))
        let list = makeList()

        window.contentView?.addSubview(list)
        editor.removeFromSuperview()

        await nextMainQueueTurn()
        #expect(window.firstResponder === list)
    }
}
