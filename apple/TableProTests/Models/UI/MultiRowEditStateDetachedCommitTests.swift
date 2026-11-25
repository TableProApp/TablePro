//
//  MultiRowEditStateDetachedCommitTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

// Stands in for the coordinator: one table per tab id, with the record each RowID holds as read.
@MainActor
private final class RecordingStager: InspectorDetachedStaging {
    static let columns = ["id", "name"]

    var tabs: [UUID: [RowID: [PluginCellValue]]] = [:]
    var staged: [(text: String, target: InspectorDetachedTarget)] = []

    func holdInspectorRows(tabId: UUID, columnIndex: Int, rowIDs: [RowID]) -> InspectorDetachedTarget? {
        guard let rows = tabs[tabId], Self.columns.indices.contains(columnIndex) else { return nil }
        var rowsAsRead: [[PluginCellValue]] = []
        for rowID in rowIDs {
            guard let row = rows[rowID] else { return nil }
            rowsAsRead.append(row)
        }
        return InspectorDetachedTarget(
            tabId: tabId, columnIndex: columnIndex, columnName: Self.columns[columnIndex], rowIDs: rowIDs, rowsAsRead: rowsAsRead
        )
    }

    func stageDetachedInspectorEdit(_ text: String, to target: InspectorDetachedTarget) {
        staged.append((text, target))
    }
}

@MainActor
struct MultiRowEditStateDetachedCommitTests {
    private let tabA = UUID()
    private let tabB = UUID()

    private func configure(_ state: MultiRowEditState, tab: UUID?, rowIDs: [RowID], values: [[String?]]) {
        state.configure(
            tabId: tab,
            rowIDs: rowIDs,
            allRows: values,
            columns: RecordingStager.columns,
            columnTypes: [.text(rawType: nil), .text(rawType: nil)]
        )
    }

    private func makeState(_ stager: RecordingStager) -> MultiRowEditState {
        stager.tabs[tabA] = [
            .existing(1): [.text("2"), .text("Bob")],
            .existing(2): [.text("3"), .text("Carol")],
        ]
        stager.tabs[tabB] = [.existing(1): [.text("9"), .text("Order")]]
        let state = MultiRowEditState()
        state.detachedStager = stager
        configure(state, tab: tabA, rowIDs: [.existing(1)], values: [["2", "Bob"]])
        return state
    }

    @Test("a commit while the window's tab and rows are shown is an ordinary field edit")
    func commitsThroughTheFieldWhileTheSelectionHolds() throws {
        let stager = RecordingStager()
        let state = makeState(stager)
        var fieldEdits: [(Int, PluginCellValue)] = []
        state.onFieldChanged = { columnIndex, value, _ in fieldEdits.append((columnIndex, value)) }
        let target = try #require(state.holdDetachedField(columnIndex: 1))

        #expect(state.commitDetachedField("Zed", to: target))

        #expect(fieldEdits.count == 1)
        #expect(stager.staged.isEmpty)
        #expect(state.fields[1].pendingValue == "Zed")
    }

    // RowIDs are positions, so another tab's selection names the same row ids as the window's.
    @Test("a commit after another tab took the inspector goes to the window's own tab, never the shown one")
    func commitsToTheOpenedTabAfterATabSwitch() throws {
        let stager = RecordingStager()
        let state = makeState(stager)
        let target = try #require(state.holdDetachedField(columnIndex: 1))
        state.onFieldChanged = { _, _, _ in Issue.record("the shown tab's field must not take the window's text") }

        configure(state, tab: tabB, rowIDs: [.existing(1)], values: [["9", "Order"]])
        #expect(state.commitDetachedField("Zed", to: target))

        #expect(stager.staged.count == 1)
        #expect(stager.staged.first?.target.tabId == tabA)
        #expect(stager.staged.first?.target.rowIDs == [.existing(1)])
        #expect(stager.staged.first?.text == "Zed")
        #expect(state.fields[1].pendingValue == nil)
    }

    @Test("a commit after the selection moved writes the rows the window was opened for")
    func commitsToTheOpenedRowsAfterTheSelectionMoved() throws {
        let stager = RecordingStager()
        let state = makeState(stager)
        let target = try #require(state.holdDetachedField(columnIndex: 1))
        state.onFieldChanged = { _, _, _ in Issue.record("the field path must not take a moved selection") }

        configure(state, tab: tabA, rowIDs: [.existing(2)], values: [["3", "Carol"]])
        #expect(state.commitDetachedField("Zed", to: target))

        #expect(stager.staged.map { $0.target.rowIDs } == [[.existing(1)]])
        #expect(state.fields[1].pendingValue == nil)
    }

    @Test("a commit is refused once another record sits at the window's row id")
    func refusesAReplacedRecord() throws {
        let stager = RecordingStager()
        let state = makeState(stager)
        let target = try #require(state.holdDetachedField(columnIndex: 1))
        state.onFieldChanged = { _, _, _ in Issue.record("a replaced record must take no edit") }

        stager.tabs[tabA]?[.existing(1)] = [.text("7"), .text("Dave")]

        #expect(!state.commitDetachedField("Zed", to: target))
        #expect(stager.staged.isEmpty)
    }

    @Test("a commit is refused once the window's tab is gone")
    func refusesAClosedTab() throws {
        let stager = RecordingStager()
        let state = makeState(stager)
        let target = try #require(state.holdDetachedField(columnIndex: 1))
        configure(state, tab: tabB, rowIDs: [.existing(1)], values: [["9", "Order"]])

        stager.tabs[tabA] = nil

        #expect(!state.commitDetachedField("Zed", to: target))
        #expect(stager.staged.isEmpty)
    }

    @Test("no window takes edits without a tab or rows to hold")
    func noHoldWithoutATabOrRows() {
        let stager = RecordingStager()
        let state = makeState(stager)

        configure(state, tab: nil, rowIDs: [.existing(1)], values: [["2", "Bob"]])
        #expect(state.holdDetachedField(columnIndex: 1) == nil)

        configure(state, tab: tabA, rowIDs: [], values: [])
        #expect(state.holdDetachedField(columnIndex: 1) == nil)
    }
}
