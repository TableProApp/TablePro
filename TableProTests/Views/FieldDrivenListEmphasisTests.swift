//
//  FieldDrivenListEmphasisTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
struct FieldDrivenListEmphasisTests {
    /// The headless test host never gives a window the keyboard, so the one input the chooser rule
    /// reads is stated here instead of hoping for real focus.
    private final class KeyWindow: NSWindow {
        var holdsKeyboard = true

        override var isKeyWindow: Bool { holdsKeyboard }
    }

    @MainActor
    private final class ChooserTableSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        func numberOfRows(in tableView: NSTableView) -> Int { 3 }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            NSTableCellView(frame: NSRect(x: 0, y: 0, width: 280, height: 28))
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = FieldDrivenRowView.make()
            rowView.followsWindowKeyState = true
            return rowView
        }
    }

    private static let windowFrame = NSRect(x: 0, y: 0, width: 300, height: 200)

    private func makeKeyWindow() -> KeyWindow {
        let window = KeyWindow(
            contentRect: Self.windowFrame, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = NSView(frame: Self.windowFrame)
        return window
    }

    private func makeWindow(isKeyWindow: Bool) -> NSWindow {
        guard !isKeyWindow else { return makeKeyWindow() }
        let window = NSWindow(
            contentRect: Self.windowFrame, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = NSView(frame: Self.windowFrame)
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

    /// The two shapes that make AppKit draw a row's selection with a material: a source list
    /// anywhere, and an inset table with a material behind it, which is what a popover is.
    private enum MaterialShape {
        case sourceList
        case insetOverMaterial
    }

    private func makeChooserTable(
        _ shape: MaterialShape,
        source: ChooserTableSource
    ) -> (host: NSView, tableView: FieldDrivenTableView) {
        let tableView = FieldDrivenTableView()
        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.backgroundColor = .clear
        tableView.style = shape == .sourceList ? .sourceList : .inset
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FieldDrivenColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.dataSource = source
        tableView.delegate = source

        let scrollView = NSScrollView(frame: Self.windowFrame)
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        tableView.reloadData()

        guard shape == .insetOverMaterial else { return (scrollView, tableView) }
        let backdrop = NSVisualEffectView(frame: Self.windowFrame)
        backdrop.material = .popover
        backdrop.addSubview(scrollView)
        return (backdrop, tableView)
    }

    private func selectionMaterial(of rowView: NSTableRowView) -> NSVisualEffectView? {
        rowView.subviews
            .compactMap { $0 as? NSVisualEffectView }
            .first { $0.material == .selection }
    }

    /// The list selects its row from a SwiftUI update, before the table has a window, and the
    /// layout pass is what builds the row there. Without it no row exists until the table is in
    /// the window, and the order the bug needs never happens.
    private func expectEmphasizedSelectionMaterial(_ shape: MaterialShape) throws {
        let source = ChooserTableSource()
        let (host, tableView) = makeChooserTable(shape, source: source)
        tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        tableView.scrollRowToVisible(1)
        host.layoutSubtreeIfNeeded()

        let rowView = try #require(tableView.rowView(atRow: 1, makeIfNecessary: false))
        let material = try #require(selectionMaterial(of: rowView))
        #expect(material.isEmphasized == false)

        let window = makeWindow(isKeyWindow: true)
        window.contentView?.addSubview(host)
        window.contentView?.layoutSubtreeIfNeeded()

        #expect(tableView.rowView(atRow: 1, makeIfNecessary: false) === rowView)
        #expect(rowView.isEmphasized)
        #expect(material.isEmphasized)
        withExtendedLifetime(source) {}
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

    /// The other half of the same regression. AppKit configures the selection material only when
    /// the selection, the stored emphasis or the key state changes. None of the three follows a
    /// row that was selected outside the window, so the material kept the unemphasized look it was
    /// built with, under cells that had turned white.
    @Test("A source list row selected before it reaches the window emphasizes its selection material")
    func sourceListChooserEmphasizesTheSelectionMaterial() throws {
        try expectEmphasizedSelectionMaterial(.sourceList)
    }

    @Test("A popover row selected before it reaches the window emphasizes its selection material")
    func popoverChooserEmphasizesTheSelectionMaterial() throws {
        try expectEmphasizedSelectionMaterial(.insetOverMaterial)
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

    @Test("A chooser row follows its window when the keyboard leaves and comes back")
    func chooserFollowsKeyStateChanges() {
        let (rowView, cell) = makeRow(followsWindowKeyState: true, isSelected: true)
        let window = makeKeyWindow()
        window.contentView?.addSubview(rowView)

        window.holdsKeyboard = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)

        #expect(rowView.isEmphasized == false)
        #expect(cell.backgroundStyle == .normal)

        window.holdsKeyboard = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

        #expect(rowView.isEmphasized)
        #expect(cell.backgroundStyle == .emphasized)
    }

    /// The popover shape. A popover's window posts no key notification of its own: it reports its
    /// parent's key state, and the parent is the object of the notification.
    @Test("A chooser row follows a key change that another window posts")
    func chooserFollowsAKeyChangePostedByAnotherWindow() {
        let (rowView, cell) = makeRow(followsWindowKeyState: true, isSelected: true)
        let window = makeKeyWindow()
        window.contentView?.addSubview(rowView)
        let parent = makeWindow(isKeyWindow: false)

        window.holdsKeyboard = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: parent)

        #expect(rowView.isEmphasized == false)
        #expect(cell.backgroundStyle == .normal)
    }

    /// A row waits in the reuse queue with no window, and must not carry the last window's
    /// emphasis into the next one.
    @Test("A chooser row drops its emphasis when it leaves the window")
    func chooserDropsEmphasisOutsideAWindow() {
        let (rowView, cell) = makeRow(followsWindowKeyState: true, isSelected: true)
        let window = makeKeyWindow()
        window.contentView?.addSubview(rowView)
        #expect(rowView.isEmphasized)

        rowView.removeFromSuperview()

        #expect(rowView.isEmphasized == false)
        #expect(cell.backgroundStyle == .normal)

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

        #expect(rowView.isEmphasized == false)
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

    @Test("A browser row leaves key changes to AppKit")
    func browserIgnoresKeyChanges() {
        let (rowView, cell) = makeRow(followsWindowKeyState: false, isSelected: true)
        let window = makeKeyWindow()
        window.contentView?.addSubview(rowView)

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

        #expect(rowView.isEmphasized == false)
        #expect(cell.backgroundStyle == .normal)
    }

    /// A chooser answers from the window, not from what AppKit hands it, because AppKit writes
    /// false the moment the search field rather than the table holds the keyboard.
    @Test("A chooser row outside a window refuses the emphasis AppKit hands it")
    func chooserIgnoresStoredEmphasis() {
        let rowView = FieldDrivenRowView.make()
        rowView.followsWindowKeyState = true

        rowView.isEmphasized = true

        #expect(rowView.isEmphasized == false)
    }

    /// The table rewrites every row on each key and first-responder change, always with false for
    /// a table that does not hold focus. In a key window that write must not land.
    @Test("A chooser row in a key window keeps its emphasis through AppKit's own write")
    func chooserKeepsEmphasisThroughAppKitWrites() {
        let (rowView, cell) = makeRow(followsWindowKeyState: true, isSelected: true)
        makeWindow(isKeyWindow: true).contentView?.addSubview(rowView)

        rowView.isEmphasized = false

        #expect(rowView.isEmphasized)
        #expect(cell.backgroundStyle == .emphasized)
    }
}
