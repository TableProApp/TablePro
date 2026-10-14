// Driven through a real NSHostingView, because the reload that lost the selection runs in
// DataGridView.updateNSView, which only SwiftUI calls.

import AppKit
import Combine
import Foundation
import SwiftUI
@testable import TablePro
import Testing

@MainActor
private final class HostedList<Content: View> {
    private let window: NSWindow
    private let host: NSHostingView<Content>

    init(_ content: Content) async {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: content)
        window.contentView = host
        await settle()
    }

    func show(_ content: Content) async {
        host.rootView = content
        await settle()
    }

    var tableView: KeyHandlingTableView? {
        Self.firstTableView(in: host)
    }

    func click(row: Int) async {
        tableView?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        await settle()
    }

    func shiftDown() async {
        guard let tableView,
              let scalar = UnicodeScalar(NSDownArrowFunctionKey),
              let event = NSEvent.keyEvent(
                  with: .keyDown,
                  location: .zero,
                  modifierFlags: .shift,
                  timestamp: 0,
                  windowNumber: window.windowNumber,
                  context: nil,
                  characters: String(Character(scalar)),
                  charactersIgnoringModifiers: String(Character(scalar)),
                  isARepeat: false,
                  keyCode: KeyCode.downArrow.rawValue
              ) else { return }
        tableView.keyDown(with: event)
        await settle()
    }

    func width(ofColumnTitled title: String) -> CGFloat? {
        tableView?.tableColumns.first { !$0.isHidden && $0.headerCell.stringValue == title }?.width
    }

    /// Each pass lays out, then waits for one main-queue turn: SwiftUI applies a change on a later
    /// run-loop turn, and a main-actor task started by the reload runs before the turn comes back.
    func settle() async {
        for _ in 0 ..< 10 {
            host.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private static func firstTableView(in view: NSView) -> KeyHandlingTableView? {
        if let tableView = view as? KeyHandlingTableView { return tableView }
        for subview in view.subviews {
            if let found = firstTableView(in: subview) { return found }
        }
        return nil
    }
}

@MainActor
private final class ListState: ObservableObject {
    @Published var rows: [StructureListRow<String>]
    @Published var selectedIDs: Set<String> = []

    init(rows: [StructureListRow<String>]) {
        self.rows = rows
    }
}

private struct ListHarness: View {
    let grid: StructureListGridModel<String>
    @ObservedObject var state: ListState
    @State private var columnLayout = ColumnLayoutState()

    var body: some View {
        let state = state
        let rows = state.rows
        var hasher = Hasher()
        hasher.combine(rows)
        return StructureListGrid(
            model: grid,
            columns: ["Name", "Timing"],
            contentKey: hasher.finalize(),
            rows: { rows },
            databaseType: .mysql,
            selectedIDs: { state.selectedIDs },
            select: { state.selectedIDs = $0 },
            sortState: nil,
            columnLayout: $columnLayout
        )
    }
}

@MainActor
struct StructureListGridSelectionTests {
    private let triggers = [
        TriggerInfo(name: "trg_b", timing: "BEFORE", event: "UPDATE", statement: "", enabled: true),
        TriggerInfo(name: "trg_a", timing: "AFTER", event: "INSERT", statement: "", enabled: false),
        TriggerInfo(name: "trg_c", timing: "AFTER", event: "DELETE", statement: ""),
    ]

    private func id(_ name: String) -> TriggerInfo.ID {
        triggers.first { $0.name == name }?.id ?? name
    }

    @Test("Reversing the sort after Shift+Down keeps both selected triggers")
    func sortAfterExtendedSelectionKeepsTheTriggers() async throws {
        let state = TriggerInspectorState()
        let list = await HostedList(TriggerListPane(triggers: triggers, databaseType: .mysql, state: state))
        let tableView = try #require(list.tableView)
        try #require(tableView.numberOfRows == 3)

        await list.click(row: 0)
        await list.shiftDown()
        try #require(state.selectedIDs == [id("trg_a"), id("trg_b")])

        let reversed = SortState(
            columns: [SortColumn(columnIndex: TriggerListColumns.nameColumn, direction: .descending, columnName: "Name")],
            source: .user
        )
        tableView.coordinator?.delegate?.dataGridSortStateChanged(reversed)
        await list.settle()
        try #require(state.displayed(triggers).map(\.name) == ["trg_c", "trg_b", "trg_a"])

        #expect(state.selectedIDs == [id("trg_a"), id("trg_b")])
        #expect(tableView.selectedRowIndexes == IndexSet([1, 2]))
        #expect(state.actionTarget(triggers) == nil)
    }

    @Test("A filter that hides a selected trigger keeps it selected for when the filter clears")
    func filterKeepsHiddenSelection() async throws {
        let state = TriggerInspectorState()
        let list = await HostedList(TriggerListPane(triggers: triggers, databaseType: .mysql, state: state))
        let tableView = try #require(list.tableView)
        await list.click(row: 0)
        await list.shiftDown()
        try #require(state.selectedIDs == [id("trg_a"), id("trg_b")])

        state.searchText = "trg_a"
        await list.settle()
        try #require(tableView.numberOfRows == 1)
        #expect(state.selectedIDs == [id("trg_a"), id("trg_b")])
        #expect(state.actionTarget(triggers)?.name == "trg_a")

        state.searchText = ""
        await list.settle()
        #expect(tableView.selectedRowIndexes == IndexSet([0, 1]))
        #expect(state.selectedIDs == [id("trg_a"), id("trg_b")])
    }

    @Test("A refresh that reorders the rows keeps a Shift+Down range by identity")
    func refreshKeepsRangeByIdentity() async throws {
        let state = ListState(rows: [
            StructureListRow(id: "a", values: ["alpha", "BEFORE"]),
            StructureListRow(id: "b", values: ["beta", "AFTER"]),
            StructureListRow(id: "c", values: ["gamma", "AFTER"]),
        ])
        let list = await HostedList(ListHarness(grid: StructureListGridModel<String>(), state: state))
        let tableView = try #require(list.tableView)
        await list.click(row: 0)
        await list.shiftDown()
        try #require(state.selectedIDs == ["a", "b"])

        state.rows.reverse()
        await list.settle()

        #expect(state.selectedIDs == ["a", "b"])
        #expect(tableView.selectedRowIndexes == IndexSet([1, 2]))
    }

    @Test("A refresh that replaces every row selects none of the new ones")
    func refreshWithNewRowsSelectsNothing() async throws {
        let state = ListState(rows: [
            StructureListRow(id: "a", values: ["alpha", "BEFORE"]),
            StructureListRow(id: "b", values: ["beta", "AFTER"]),
        ])
        let list = await HostedList(ListHarness(grid: StructureListGridModel<String>(), state: state))
        let tableView = try #require(list.tableView)
        await list.click(row: 0)
        await list.shiftDown()
        try #require(state.selectedIDs == ["a", "b"])

        state.selectedIDs = []
        state.rows = [
            StructureListRow(id: "d", values: ["delta", "BEFORE"]),
            StructureListRow(id: "e", values: ["epsilon", "AFTER"]),
        ]
        await list.settle()

        #expect(state.selectedIDs.isEmpty)
        #expect(tableView.selectedRowIndexes.isEmpty)
    }

    @Test("Trigger columns open at the widths the list has always given them")
    func triggerColumnWidths() async {
        let withEnabled = await HostedList(TriggerListPane(triggers: triggers, databaseType: .mysql, state: TriggerInspectorState()))
        #expect(withEnabled.width(ofColumnTitled: String(localized: "Name")) == 220)
        #expect(withEnabled.width(ofColumnTitled: String(localized: "Timing")) == 90)
        #expect(withEnabled.width(ofColumnTitled: String(localized: "Event")) == 150)
        #expect(withEnabled.width(ofColumnTitled: String(localized: "Enabled")) == 70)

        let unknownEnabled = triggers.map {
            TriggerInfo(name: $0.name, timing: $0.timing, event: $0.event, statement: "")
        }
        let withoutEnabled = await HostedList(TriggerListPane(
            triggers: unknownEnabled, databaseType: .mysql, state: TriggerInspectorState()
        ))
        #expect(withoutEnabled.width(ofColumnTitled: String(localized: "Name")) == 240)
        #expect(withoutEnabled.width(ofColumnTitled: String(localized: "Event")) == 160)
        #expect(withoutEnabled.width(ofColumnTitled: String(localized: "Enabled")) == nil)
    }
}
