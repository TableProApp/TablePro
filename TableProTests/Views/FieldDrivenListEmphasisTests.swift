//
//  FieldDrivenListEmphasisTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@Suite("Field driven list row emphasis")
@MainActor
struct FieldDrivenListEmphasisTests {
    /// The headless test host never gives a window the keyboard, so the one input the chooser rule
    /// reads is stated here instead of hoping for real focus.
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    private func makeWindow(isKeyWindow: Bool) -> NSWindow {
        let frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        let window = isKeyWindow
            ? KeyWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            : NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSView(frame: frame)
        return window
    }

    /// AppKit populates a row view before it adds that row to the table, so this is the order the
    /// framework really uses and the order the bug lived in.
    private func makeRow(followsWindowKeyState: Bool, isSelected: Bool) -> (FieldDrivenRowView, NSTableCellView) {
        let rowView = FieldDrivenRowView.make()
        rowView.followsWindowKeyState = followsWindowKeyState
        rowView.isSelected = isSelected
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        rowView.addSubview(cell)
        return (rowView, cell)
    }

    /// The regression. AppKit copies `interiorBackgroundStyle` into the cell views while the row is
    /// still outside the window, where a key-state-derived emphasis can only read false, and it
    /// never repeats the copy when the row arrives. The row then painted its accent fill from the
    /// live value over cells that had kept the unemphasized foreground.
    @Test("A chooser row emphasizes cells that were installed before it reached the window")
    func chooserEmphasizesCellsInstalledBeforeTheWindow() {
        let (rowView, cell) = makeRow(followsWindowKeyState: true, isSelected: true)
        #expect(cell.backgroundStyle == .normal)

        makeWindow(isKeyWindow: true).contentView?.addSubview(rowView)

        #expect(cell.backgroundStyle == .emphasized)
    }

    @Test("A chooser row leaves an unselected row's cells alone")
    func chooserLeavesUnselectedCellsAlone() {
        let (rowView, cell) = makeRow(followsWindowKeyState: true, isSelected: false)

        makeWindow(isKeyWindow: true).contentView?.addSubview(rowView)

        #expect(cell.backgroundStyle == .normal)
    }

    @Test("A chooser row in a window without the keyboard is not emphasized")
    func chooserNeedsTheKeyWindow() {
        let (rowView, cell) = makeRow(followsWindowKeyState: true, isSelected: true)

        makeWindow(isKeyWindow: false).contentView?.addSubview(rowView)

        #expect(cell.backgroundStyle == .normal)
        #expect(rowView.isEmphasized == false)
    }

    @Test("A chooser row is emphasized as soon as it is in a key window")
    func chooserReadsTheWindow() {
        let (rowView, _) = makeRow(followsWindowKeyState: true, isSelected: true)
        #expect(rowView.isEmphasized == false)

        makeWindow(isKeyWindow: true).contentView?.addSubview(rowView)

        #expect(rowView.isEmphasized)
        #expect(rowView.interiorBackgroundStyle == .emphasized)
    }

    /// A browser holds its own focus, so AppKit's stored value is the right answer and the setter
    /// has to forward. Swallowing the write would leave every row of the query history drawer
    /// permanently unemphasized.
    /// The starting value matters as much as the forwarding: a browser row is built before AppKit
    /// has said anything about it, and cells are copied from it in that state. `NSTableRowView`
    /// starts unemphasized, so an untouched row reads as unemphasized too.
    @Test("A browser row reports the emphasis AppKit gave it")
    func browserForwardsStoredEmphasis() {
        let rowView = FieldDrivenRowView.make()
        #expect(rowView.isEmphasized == false)

        rowView.isEmphasized = true
        #expect(rowView.isEmphasized)

        rowView.isEmphasized = false
        #expect(rowView.isEmphasized == false)
    }

    /// A chooser answers from the window, not from what AppKit stored, because AppKit drops
    /// emphasis the moment the search field rather than the table holds the keyboard.
    @Test("A chooser row ignores the emphasis AppKit stored")
    func chooserIgnoresStoredEmphasis() {
        let rowView = FieldDrivenRowView.make()
        rowView.followsWindowKeyState = true

        rowView.isEmphasized = true

        #expect(rowView.isEmphasized == false)
    }
}
