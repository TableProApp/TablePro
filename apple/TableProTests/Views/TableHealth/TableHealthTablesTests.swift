import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import Testing

// The checks list and the findings table were SwiftUI, whose cell hosting view takes a row click without making
// the list first responder: the selection drew grey and the arrow keys went to the database sidebar.
@MainActor
struct TableHealthTablesTests {
    // The test host never gives a window the keyboard, so the window says it has it. AppKit still draws no
    // emphasis here, so the accent selection is measured in the running app; this pins the first responder
    // AppKit derives it from.
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    @MainActor
    private final class State {
        var selection: Set<TableHealthFindingID> = []
        var sortOrder: [KeyPathComparator<TableHealthFindingRow>] = [KeyPathComparator(\TableHealthFindingRow.checkOrder)]
        var scope: TableHealthScope = .all
        var primaryActionRows: [[TableHealthFindingID]] = []
    }

    private struct Hosted {
        let window: KeyWindow
        let other: NSTextField
        let root: NSView

        func first<Found: NSView>(_ type: Found.Type) -> Found? {
            Self.descendants(of: root).lazy.compactMap { $0 as? Found }.first
        }

        private static func descendants(of view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants(of:))
        }

        func close() {
            window.orderOut(nil)
        }
    }

    private nonisolated static func row(_ table: String, kind: TableHealthCheckKind = .missingPrimaryKey) -> TableHealthFindingRow {
        TableHealthFindingRow(
            finding: TableHealthFixture.finding(kind, table: table),
            checkTitle: kind.title,
            checkOrder: 0,
            status: .seen,
            firstSeen: nil,
            lastSeen: nil
        )
    }

    private nonisolated static let rows = ["orders", "events", "audit_log"].map { row($0) }

    // The keyboard starts in another view, the way the database sidebar holds it when the tab opens.
    private func host(_ content: some View) -> Hosted {
        let frame = NSRect(x: 0, y: 0, width: 700, height: 420)
        let window = KeyWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: frame)
        let other = NSTextField(frame: NSRect(x: 0, y: 390, width: 200, height: 22))
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 380)
        container.addSubview(hosting)
        container.addSubview(other)
        window.contentView = container
        hosting.layoutSubtreeIfNeeded()
        window.makeFirstResponder(other)
        return Hosted(window: window, other: other, root: hosting)
    }

    // A click goes to the view under the pointer, which is what a SwiftUI cell took for itself. NSTableView
    // tracks the press until the mouse-up, so the mouse-up waits in the queue first.
    private func click(row: Int, in tableView: NSTableView, window: NSWindow) throws {
        tableView.layoutSubtreeIfNeeded()
        let rect = tableView.rect(ofRow: row)
        let location = tableView.convert(NSPoint(x: rect.minX + 40, y: rect.midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ))
        }
        let up = try event(.leftMouseUp)
        let down = try event(.leftMouseDown)
        let target = try #require(window.contentView?.hitTest(location))
        NSApp.postEvent(up, atStart: true)
        target.mouseDown(with: down)
        _ = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
    }

    private func press(_ key: KeyCode, characters: String, in view: NSView, window: NSWindow) throws {
        let modifiers: NSEvent.ModifierFlags = key.isArrowKey ? [.numericPad, .function] : []
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: key.rawValue
        ))
        view.keyDown(with: event)
    }

    private func pressDownArrow(in view: NSView, window: NSWindow) throws {
        try press(.downArrow, characters: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), in: view, window: window)
    }

    private func findingsTable(_ state: State) -> TableHealthRowsTable {
        TableHealthRowsTable(
            rows: Self.rows,
            columns: TableHealthFindingsTable.columns,
            selection: Binding(get: { state.selection }, set: { state.selection = $0 }),
            sortOrder: Binding(get: { state.sortOrder }, set: { state.sortOrder = $0 }),
            accessibilityLabel: "Findings",
            menu: TableHealthRowMenu.findings,
            perform: { _, _ in },
            primaryAction: { rows in state.primaryActionRows.append(rows.map(\.id)) },
            copyText: { nil }
        )
    }

    @Test("A click on a finding takes the keyboard, the arrow keys move it, and Return opens it")
    func clickFocusesTheFindingsTable() throws {
        let state = State()
        let hosted = host(findingsTable(state))
        defer { hosted.close() }
        let tableView = try #require(hosted.first(TableHealthNSTableView.self))
        #expect(hosted.window.firstResponder !== tableView)

        try click(row: 1, in: tableView, window: hosted.window)

        #expect(hosted.window.firstResponder === tableView)
        #expect(state.selection == [Self.rows[1].id])

        try pressDownArrow(in: tableView, window: hosted.window)
        #expect(state.selection == [Self.rows[2].id])

        try press(.return, characters: "\r", in: tableView, window: hosted.window)
        #expect(state.primaryActionRows == [[Self.rows[2].id]])
    }

    @Test("A click on a check takes the keyboard, and the arrow keys skip the section headers")
    func clickFocusesTheChecksList() throws {
        let state = State()
        let sections = [
            TableHealthChecksSection(title: nil, rows: [
                TableHealthChecksRow(scope: .all, title: "All Findings", systemImage: "tray.full", badge: "3", toolTip: nil),
            ]),
            TableHealthChecksSection(title: "Checks", rows: [
                TableHealthChecksRow(
                    scope: .check(.missingPrimaryKey), title: "Keys", systemImage: "key", badge: "3", toolTip: nil
                ),
                TableHealthChecksRow(
                    scope: .check(.unusedIndex), title: "Unused", systemImage: "list.bullet.indent", badge: nil, toolTip: nil
                ),
            ]),
            TableHealthChecksSection(title: "History", rows: [
                TableHealthChecksRow(
                    scope: .resolved, title: "Resolved", systemImage: "clock.arrow.circlepath", badge: nil, toolTip: nil
                ),
            ]),
        ]
        let hosted = host(TableHealthChecksOutline(
            sections: sections,
            scope: Binding(get: { state.scope }, set: { state.scope = $0 }),
            menu: { _ in [] },
            perform: { _ in },
            copyText: { nil }
        ))
        defer { hosted.close() }
        let outlineView = try #require(hosted.first(TableHealthChecksNSOutlineView.self))
        #expect(outlineView.selectedRow == 0)

        // Rows: All Findings, the Checks header, Keys, Unused, the History header, Resolved.
        try click(row: 3, in: outlineView, window: hosted.window)

        #expect(hosted.window.firstResponder === outlineView)
        #expect(state.scope == .check(.unusedIndex))

        try pressDownArrow(in: outlineView, window: hosted.window)
        #expect(state.scope == .resolved)
    }

    @Test("A header click becomes the view model's comparators, and its sort shows on the header")
    func sortDescriptorsMapToComparators() {
        let columns = TableHealthFindingsTable.columns.map(\.column)
        let comparators = TableHealthTableSort.comparators(
            for: [NSSortDescriptor(key: "table", ascending: false), NSSortDescriptor(key: "check", ascending: true)],
            columns: columns
        )

        let sorted = Self.rows.sorted(using: comparators).map { $0.tableSortKey }
        #expect(sorted == ["public.orders", "public.events", "public.audit_log"])
        let descriptors = TableHealthTableSort.descriptors(for: comparators, columns: columns)
        #expect(descriptors.map { $0.key } == ["table", "check"])
        #expect(descriptors.map { $0.ascending } == [false, true])
    }

    @Test("The Resolved table shows its newest-first sort on the Last Seen header")
    func resolvedSortShowsOnItsHeader() {
        let descriptors = TableHealthTableSort.descriptors(
            for: [KeyPathComparator(\TableHealthFindingRow.lastSeenSortKey, order: .reverse)],
            columns: TableHealthResolvedTable.columns.map(\.column)
        )

        #expect(descriptors.map { $0.key } == ["lastSeen"])
        #expect(descriptors.map { $0.ascending } == [false])
    }

    @Test("A finding's menu leaves out what does not apply")
    func findingsMenuLeavesOutWhatDoesNotApply() {
        let twoTables = TableHealthRowMenu.findings([Self.rows[0], Self.rows[1]])
        let titles = twoTables.map { section in
            section.items.compactMap { item -> String? in
                guard case .command(let entry) = item else { return nil }
                return entry.title
            }
        }

        #expect(titles == [
            ["Open Fixes in Editor"],
            ["Copy", "Copy Fix SQL"],
            ["Ignore", "Save Fix Script…"],
        ])
        #expect(TableHealthRowMenu.findings([]).isEmpty)
        #expect(TableHealthRowMenu.checks(scope: .resolved, resolvedCount: 0).isEmpty)
        #expect(TableHealthRowMenu.checks(scope: .resolved, resolvedCount: 2).count == 1)
        #expect(TableHealthRowMenu.resolved([]).nonEmptySections().count == 1)
    }
}
