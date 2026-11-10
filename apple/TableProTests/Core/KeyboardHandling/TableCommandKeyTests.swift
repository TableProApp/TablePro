import AppKit
import Testing

@testable import TablePro

@MainActor
struct TableCommandKeyTests {
    private final class RecordingOutline: SidebarOutlineView {
        var commands: [String] = []

        override func insertNewline(_ sender: Any?) { commands.append("insertNewline") }
        override func deleteBackward(_ sender: Any?) { commands.append("deleteBackward") }
        override func deleteForward(_ sender: Any?) { commands.append("deleteForward") }
    }

    private final class KeyRecordingView: NSView {
        var keyDowns = 0

        override func keyDown(with event: NSEvent) { keyDowns += 1 }
    }

    private final class RailController: NSViewController {
        var opened = 0

        override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120)) }
        override func insertNewline(_ sender: Any?) { opened += 1 }
    }

    private final class Rows: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource {
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            item == nil ? 3 : 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            "row \(index)"
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            NSTableCellView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        }

        func numberOfRows(in tableView: NSTableView) -> Int { 3 }
    }

    private enum Key {
        case returnKey, enter, delete, forwardDelete, down

        var code: KeyCode {
            switch self {
            case .returnKey: .return
            case .enter: .enter
            case .delete: .delete
            case .forwardDelete: .forwardDelete
            case .down: .downArrow
            }
        }

        var characters: String {
            switch self {
            case .returnKey: "\r"
            case .enter: "\u{3}"
            case .delete: "\u{7F}"
            case .forwardDelete: "\u{F728}"
            case .down: "\u{F701}"
            }
        }
    }

    private func press(_ key: Key, modifiers: NSEvent.ModifierFlags = [], in table: NSTableView) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: table.window?.windowNumber ?? 0,
            context: nil,
            characters: key.characters,
            charactersIgnoringModifiers: key.characters,
            isARepeat: false,
            keyCode: key.code.rawValue
        ))
        table.keyDown(with: event)
    }

    private func mount<Table: NSTableView>(_ table: Table, in container: NSView, rows: Rows) -> NSWindow {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        table.addTableColumn(column)
        table.headerView = nil
        if let outline = table as? NSOutlineView {
            outline.outlineTableColumn = column
            outline.dataSource = rows
            outline.delegate = rows
        } else {
            table.dataSource = rows
        }
        let scrollView = NSScrollView(frame: container.bounds)
        scrollView.documentView = table
        container.addSubview(scrollView)
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        table.reloadData()
        window.makeFirstResponder(table)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        return window
    }

    @Test("Return and keypad Enter reach insertNewline on the outline")
    func returnRunsInsertNewline() throws {
        let rows = Rows()
        let outline = RecordingOutline()
        let window = mount(outline, in: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120)), rows: rows)

        try press(.returnKey, in: outline)
        try press(.enter, in: outline)

        #expect(outline.commands == ["insertNewline", "insertNewline"])
        _ = window
    }

    @Test("Delete and Forward Delete reach their delete commands")
    func deleteRunsDeleteCommands() throws {
        let rows = Rows()
        let outline = RecordingOutline()
        let window = mount(outline, in: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120)), rows: rows)

        try press(.delete, in: outline)
        try press(.forwardDelete, in: outline)

        #expect(outline.commands == ["deleteBackward", "deleteForward"])
        _ = window
    }

    @Test("A key with a modifier is not turned into a command")
    func modifiedKeysStayKeys() throws {
        let rows = Rows()
        let outline = RecordingOutline()
        let window = mount(outline, in: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120)), rows: rows)

        try press(.delete, modifiers: .shift, in: outline)
        try press(.returnKey, modifiers: .shift, in: outline)

        #expect(outline.commands.isEmpty)
        _ = window
    }

    @Test("An arrow key still moves the selection")
    func arrowMovesSelection() throws {
        let rows = Rows()
        let outline = RecordingOutline()
        let window = mount(outline, in: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120)), rows: rows)

        try press(.down, in: outline)

        #expect(outline.selectedRow == 2)
        #expect(outline.commands.isEmpty)
        _ = window
    }

    @Test("Return nobody answers keeps travelling up, so a default button can take it")
    func unansweredReturnPassesUp() throws {
        let rows = Rows()
        let outline = SidebarOutlineView()
        let container = KeyRecordingView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let window = mount(outline, in: container, rows: rows)

        try press(.returnKey, in: outline)

        #expect(container.keyDowns == 1)
        _ = window
    }

    @Test("Return on the connections strip reaches its controller")
    func railReturnReachesController() throws {
        let rows = Rows()
        let controller = RailController()
        let table = WorkspaceRailTableView(frame: .zero)
        let window = mount(table, in: controller.view, rows: rows)

        try press(.returnKey, in: table)

        #expect(controller.opened == 1)
        _ = window
    }
}
