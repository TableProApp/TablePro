//
//  NSViewDescendantsTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
struct NSViewDescendantsTests {
    private func nested(_ leaf: NSView) -> NSView {
        let root = NSView()
        let middle = NSView()
        root.addSubview(middle)
        middle.addSubview(leaf)
        return root
    }

    @Test("A typed search reaches a view several levels down")
    func findsANestedViewByType() throws {
        let outline = NSOutlineView()
        let root = nested(NSScrollView())
        try #require(root.subviews.first?.subviews.first as? NSScrollView).documentView = outline

        #expect(root.firstDescendant(of: NSOutlineView.self) === outline)
    }

    @Test("A typed search finds a subclass through its base type")
    func findsASubclassThroughItsBase() {
        let table = NSTableView()
        let root = nested(table)

        #expect(root.firstDescendant(of: NSButton.self) == nil)
        #expect(root.firstDescendant(of: NSControl.self) === table)
        #expect(root.firstDescendant(of: NSTableView.self) === table)
    }

    @Test("A typed search answers nil rather than the wrong view")
    func answersNilWhenAbsent() {
        #expect(nested(NSView()).firstDescendant(of: NSOutlineView.self) == nil)
    }

    /// The rule a focus command uses for a pane with no one obvious target. It has to match what Tab
    /// would do, which is `canBecomeKeyView` and not `acceptsFirstResponder`: a scroll view and a
    /// clip view both accept first responder and neither is ever a Tab stop, so a search on the
    /// looser rule would hand the keyboard to the scroll view wrapping the control.
    ///
    /// The window is not scenery. Measured on macOS 27: a detached `NSTextField` answers
    /// `acceptsFirstResponder` true and `canBecomeKeyView` FALSE, and only reports true once it is
    /// in a key window. That is why the focus commands resolve against a pane that is on screen.
    @Test("The key-view search skips a view Tab would skip")
    func skipsViewsTabWouldSkip() {
        let field = NSTextField()
        let scrollView = NSScrollView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = root
        root.addSubview(scrollView)
        scrollView.frame = root.bounds
        scrollView.documentView = field
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        defer { window.close() }

        #expect(scrollView.acceptsFirstResponder)
        #expect(!scrollView.canBecomeKeyView)
        #expect(root.firstKeyViewDescendant === field)
    }

    @Test("The key-view search answers nil when nothing can take the keyboard")
    func answersNilWhenNothingTakesFocus() {
        #expect(nested(NSView()).firstKeyViewDescendant == nil)
    }
}
