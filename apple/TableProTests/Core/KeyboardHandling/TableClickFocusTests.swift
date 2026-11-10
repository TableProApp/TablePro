import AppKit
import SwiftUI
import Testing

@testable import TablePro

@MainActor
struct TableClickFocusTests {
    // Stands in for SwiftUI's backing table: defined outside AppKit and the app, it hands a click to the view under it.
    private class PassThroughTable: NSTableView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            for rowView in subviews.reversed() {
                if let inner = rowView.hitTest(local) { return inner }
            }
            return super.hitTest(point)
        }
    }

    private final class RefusingPassThroughTable: PassThroughTable {
        override var acceptsFirstResponder: Bool { false }
    }

    private final class Tile: NSView {}

    private final class Cells: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let editable: Bool
        let tiles: Bool

        init(editable: Bool, tiles: Bool) {
            self.editable = editable
            self.tiles = tiles
        }

        func numberOfRows(in tableView: NSTableView) -> Int { 4 }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            if tiles { return Tile(frame: NSRect(x: 0, y: 0, width: 280, height: 24)) }
            let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            guard editable else { return cell }
            let field = NSTextField(string: "row \(row)")
            field.frame = cell.bounds
            field.autoresizingMask = [.width, .height]
            cell.addSubview(field)
            return cell
        }
    }

    private struct SwiftUIRows: View {
        let selection: Set<Int>

        var body: some View {
            List(selection: .constant(selection)) {
                ForEach(0 ..< 4, id: \.self) { Text("row \($0)").tag($0) }
            }
        }
    }

    @MainActor
    private struct Stage {
        let window: NSWindow
        let table: NSTableView
        let cells: Cells?

        var fields: [NSTextField] { window.contentView?.subviews.compactMap { $0 as? NSTextField } ?? [] }

        func event(_ type: NSEvent.EventType, row: Int, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            let cell = table.frameOfCell(atColumn: 0, row: row)
            let point = table.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil)
            let event = try #require(NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ))
            try #require(event.window === window)
            return event
        }

        func hitView(atRow row: Int) throws -> NSView {
            let point = try event(.leftMouseDown, row: row).locationInWindow
            return try #require(window.contentView?.superview?.hitTest(point))
        }

        var tableHoldsFocus: Bool { window.firstResponder === table }
    }

    private static let frame = NSRect(x: 0, y: 0, width: 300, height: 220)

    private static func makeWindow(holding list: NSView) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: frame)
        let field = NSTextField(frame: NSRect(x: 0, y: 190, width: 150, height: 24))
        let otherField = NSTextField(frame: NSRect(x: 150, y: 190, width: 150, height: 24))
        list.frame = NSRect(x: 0, y: 0, width: 300, height: 180)
        content.addSubview(field)
        content.addSubview(otherField)
        content.addSubview(list)
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        window.makeFirstResponder(field)
        return window
    }

    private func stage(_ table: NSTableView, editable: Bool = false, tiles: Bool = false, selectedRow: Int? = nil) -> Stage {
        let cells = Cells(editable: editable, tiles: tiles)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.width = 280
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = cells
        table.delegate = cells
        let scrollView = NSScrollView()
        scrollView.documentView = table
        let window = Self.makeWindow(holding: scrollView)
        table.reloadData()
        if let selectedRow {
            table.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        }
        scrollView.layoutSubtreeIfNeeded()
        return Stage(window: window, table: table, cells: cells)
    }

    private static func stageSwiftUIList(selection: Set<Int> = []) -> Stage? {
        let host = NSHostingView(rootView: SwiftUIRows(selection: selection))
        let window = makeWindow(holding: host)
        guard let table = firstTable(in: host) else { return nil }
        return Stage(window: window, table: table, cells: nil)
    }

    private static func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { firstTable(in: $0) }.first
    }

    // The private view tree behind a SwiftUI List differs between OS builds, so this asks the host.
    static func swiftUIListHandsClicksToItsCells() -> Bool {
        guard let stage = stageSwiftUIList(), let hit = try? stage.hitView(atRow: 1) else { return false }
        return hit !== stage.table && hit.isDescendant(of: stage.table) && !hit.acceptsFirstResponder
    }

    private func click(row: Int, in stage: Stage, modifiers: NSEvent.ModifierFlags = [], with focus: TableClickFocus) async throws {
        focus.handle(try stage.event(.leftMouseDown, row: row, modifiers: modifiers))
        focus.handle(try stage.event(.leftMouseUp, row: row, modifiers: modifiers))
        await drainMainQueue()
    }

    @Test("A click on an unselected row gives the table focus once the mouse is up")
    func unselectedRowClaimsAfterMouseUp() async throws {
        let stage = stage(PassThroughTable())
        let focus = TableClickFocus()

        focus.handle(try stage.event(.leftMouseDown, row: 1))
        #expect(!stage.tableHoldsFocus)
        focus.handle(try stage.event(.leftMouseUp, row: 1))
        await drainMainQueue()

        #expect(stage.tableHoldsFocus)
    }

    @Test("A press on a selected row gives the table focus at once")
    func selectedRowClaimsAtMouseDown() throws {
        let stage = stage(PassThroughTable(), selectedRow: 2)
        let focus = TableClickFocus()

        focus.handle(try stage.event(.leftMouseDown, row: 2))

        #expect(stage.tableHoldsFocus)
    }

    @Test("A focus the click itself moves to another view stays there")
    func focusMovedByTheClickStays() async throws {
        let stage = stage(PassThroughTable())
        let focus = TableClickFocus()
        let other = try #require(stage.fields.last)

        focus.handle(try stage.event(.leftMouseDown, row: 1))
        stage.window.makeFirstResponder(other)
        focus.handle(try stage.event(.leftMouseUp, row: 1))
        await drainMainQueue()

        #expect(!stage.tableHoldsFocus)
        #expect((stage.window.firstResponder as? NSTextView)?.delegate === other)
    }

    @Test("A focus the click leaves vacant goes to the table")
    func vacatedFocusGoesToTheTable() async throws {
        let stage = stage(PassThroughTable())
        let focus = TableClickFocus()

        focus.handle(try stage.event(.leftMouseDown, row: 1))
        stage.fields.first?.removeFromSuperview()
        focus.handle(try stage.event(.leftMouseUp, row: 1))
        await drainMainQueue()

        #expect(stage.tableHoldsFocus)
    }

    @Test("A Control-click opens a menu and leaves focus where it was")
    func controlClickLeavesFocus() async throws {
        let stage = stage(PassThroughTable())

        try await click(row: 1, in: stage, modifiers: .control, with: TableClickFocus())

        #expect(!stage.tableHoldsFocus)
    }

    @Test("A click on a text field in a row is left to the field")
    func focusableHitViewIsLeftAlone() async throws {
        let stage = stage(PassThroughTable(), editable: true)
        try #require(try stage.hitView(atRow: 1) is NSTextField)

        try await click(row: 1, in: stage, with: TableClickFocus())

        #expect(!stage.tableHoldsFocus)
    }

    @Test("An AppKit table keeps its own click handling, even where it hands the click to a cell")
    func appKitTableIsLeftAlone() throws {
        let stage = stage(NSTableView(), tiles: true, selectedRow: 1)
        try #require(try stage.hitView(atRow: 1) is Tile)

        TableClickFocus().handle(try stage.event(.leftMouseDown, row: 1))

        #expect(!stage.tableHoldsFocus)
    }

    @Test("A table the app defines is left to its own mouseDown, even where it hands the click to a cell")
    func appTableIsLeftAlone() throws {
        let stage = stage(WorkspaceRailTableView(frame: .zero), tiles: true, selectedRow: 1)
        try #require(try stage.hitView(atRow: 1) is Tile)

        TableClickFocus().handle(try stage.event(.leftMouseDown, row: 1))

        #expect(!stage.tableHoldsFocus)
    }

    @Test("A table that refuses focus keeps refusing it")
    func refusingTableIsLeftAlone() async throws {
        let stage = stage(RefusingPassThroughTable())

        try await click(row: 1, in: stage, with: TableClickFocus())

        #expect(!stage.tableHoldsFocus)
    }

    @Test(
        "A click on a SwiftUI List row gives the list focus",
        .enabled("The host's SwiftUI List keeps clicks on its table") {
            await TableClickFocusTests.swiftUIListHandsClicksToItsCells()
        }
    )
    func swiftUIListRowClaims() async throws {
        let stage = try #require(Self.stageSwiftUIList())

        try await click(row: 1, in: stage, with: TableClickFocus())

        #expect(stage.tableHoldsFocus)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
