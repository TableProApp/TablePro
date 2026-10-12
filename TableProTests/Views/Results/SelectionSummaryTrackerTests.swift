//
//  SelectionSummaryTrackerTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProNumberFormatting
import TableProPluginKit
import Testing

@MainActor
private final class SummaryLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@MainActor
private final class SummaryRowStore {
    var tableRows: TableRows

    init(_ tableRows: TableRows) {
        self.tableRows = tableRows
    }
}

@MainActor
private final class SummaryInputBox {
    var input: SelectionSummaryInput?

    init(_ input: SelectionSummaryInput?) {
        self.input = input
    }
}

/// Holds the first computation open until the test lets it go, after it has its result.
private actor SummaryComputeGate {
    private var callCount = 0
    private var hasEntered = false
    private var isOpen = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func compute(_ input: SelectionSummaryInput) async throws -> SelectionSummary {
        callCount += 1
        let isFirst = callCount == 1
        let summary = try await SelectionSummaryCalculator().summarize(input)
        guard isFirst else { return summary }
        hasEntered = true
        for waiter in enteredWaiters { waiter.resume() }
        enteredWaiters.removeAll()
        if !isOpen {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return summary
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }
}

@MainActor
struct SelectionSummaryTrackerTests {
    private static let integer = ColumnType.integer(rawType: "INT")

    private func makeGrid(
        _ rows: [[PluginCellValue]],
        types: [ColumnType],
        state: SelectionSummaryState? = SelectionSummaryState(),
        changeManager: DataChangeManager = DataChangeManager()
    ) -> (TableViewCoordinator, SummaryRowStore) {
        let view = DataGridView(
            changeManager: AnyChangeManager(changeManager),
            isEditable: true,
            layoutPersister: SummaryLayoutPersister(),
            selectedRowIndices: .constant([]),
            sortState: .constant(SortState()),
            columnLayout: .constant(ColumnLayoutState()),
            selectionSummary: state
        )
        let coordinator = view.makeCoordinator()
        let store = SummaryRowStore(TableRows.from(
            queryRows: rows,
            columns: types.indices.map { "c\($0)" },
            columnTypes: types
        ))
        coordinator.tableRowsProvider = { store.tableRows }
        coordinator.tableRowsMutator = { mutation in mutation(&store.tableRows) }
        coordinator.updateCache()
        return (coordinator, store)
    }

    private static func block(rows: ClosedRange<Int>, columns: ClosedRange<Int>) -> GridSelection {
        .single(
            GridRect(rows: rows, columns: columns),
            anchor: GridCoord(row: rows.lowerBound, displayColumn: columns.lowerBound),
            active: GridCoord(row: rows.upperBound, displayColumn: columns.upperBound)
        )
    }

    private static func standaloneInput(_ values: [String]) -> SelectionSummaryInput {
        let tableRows = TableRows.from(queryRows: values.map { [.text($0)] }, columns: ["n"], columnTypes: [integer])
        return SelectionSummaryInput(
            selection: block(rows: 0...(values.count - 1), columns: 0...0),
            tableRows: tableRows,
            dataColumnsByDisplayPosition: [0],
            policy: .derived(columnTypes: [integer], displayFormats: [], columnCount: 1)
        )
    }

    @Test("widening a selection sideways recomputes, though the selected rows stay the same")
    func horizontalWideningRecomputes() async {
        let state = SelectionSummaryState()
        let (coordinator, _) = makeGrid(
            [[.text("1"), .text("10")], [.text("2"), .text("20")]],
            types: [Self.integer, Self.integer],
            state: state
        )
        let tracker = coordinator.selectionSummaryTracker

        coordinator.selectionController.update(Self.block(rows: 0...1, columns: 0...0))
        await tracker.pendingTask?.value
        #expect(state.summary?.numbers?.sum.decimal == 3)
        let narrow = state.summary

        coordinator.selectionController.update(Self.block(rows: 0...1, columns: 0...1))
        #expect(state.summary == narrow)
        #expect(tracker.currentSummary == nil)
        await tracker.pendingTask?.value

        #expect(state.summary?.numbers?.sum.decimal == 33)
        #expect(state.summary?.valueCount == 4)
        #expect(tracker.currentSummary == state.summary)
    }

    @Test("an edit inside the selection recomputes the summary")
    func editInsideSelectionRecomputes() async {
        let state = SelectionSummaryState()
        let (coordinator, _) = makeGrid([[.text("1")], [.text("2")]], types: [Self.integer], state: state)
        let tracker = coordinator.selectionSummaryTracker
        coordinator.selectionController.update(Self.block(rows: 0...1, columns: 0...0))
        await tracker.pendingTask?.value
        #expect(state.summary?.numbers?.sum.decimal == 3)

        coordinator.commitCellEdit(row: 0, columnIndex: 0, newValue: "5")
        await tracker.pendingTask?.value

        #expect(state.summary?.numbers?.sum.decimal == 7)
    }

    @Test("a cell set to Default by an edit counts as empty, not as text")
    func stagedDefaultIsEmpty() async {
        let state = SelectionSummaryState()
        let (coordinator, _) = makeGrid([[.text("1")], [.text("2")]], types: [Self.integer], state: state)
        let tracker = coordinator.selectionSummaryTracker
        coordinator.selectionController.update(Self.block(rows: 0...1, columns: 0...0))

        coordinator.commitCellEdit(row: 1, columnIndex: 0, newValue: PluginCellValue.defaultMarkerText)
        await tracker.pendingTask?.value

        #expect(state.summary?.emptyCount == 1)
        #expect(state.summary?.notANumberCount == 0)
        #expect(state.summary?.numbers?.sum.decimal == 1)
    }

    @Test("narrowing to a single cell takes the summary down")
    func singleCellClears() async {
        let state = SelectionSummaryState()
        let (coordinator, _) = makeGrid([[.text("1")], [.text("2")]], types: [Self.integer], state: state)
        let tracker = coordinator.selectionSummaryTracker
        coordinator.selectionController.update(Self.block(rows: 0...1, columns: 0...0))
        await tracker.pendingTask?.value
        #expect(state.summary != nil)

        coordinator.selectionController.update(Self.block(rows: 1...1, columns: 0...0))
        await tracker.pendingTask?.value

        #expect(state.summary == nil)
        #expect(tracker.currentSummary == nil)
    }

    @Test("a grid with no summary state computes nothing")
    func gridWithoutStateComputesNothing() {
        let (coordinator, _) = makeGrid([[.text("1")], [.text("2")]], types: [Self.integer], state: nil)

        coordinator.selectionController.update(Self.block(rows: 0...1, columns: 0...0))

        #expect(coordinator.selectionSummaryTracker.pendingTask == nil)
        #expect(coordinator.selectionSummaryTracker.currentSummary == nil)
    }

    @Test("a result computed for an older selection is never published")
    func staleGenerationNeverPublishes() async {
        let gate = SummaryComputeGate()
        let box = SummaryInputBox(Self.standaloneInput(["1", "2"]))
        let tracker = SelectionSummaryTracker(
            inputProvider: { box.input },
            compute: { try await gate.compute($0) }
        )
        let state = SelectionSummaryState()
        tracker.attach(state)
        let stale = tracker.pendingTask
        await gate.waitUntilEntered()

        box.input = Self.standaloneInput(["10", "20"])
        tracker.dataDidChange()
        await gate.open()
        await stale?.value
        await tracker.pendingTask?.value

        #expect(state.summary?.numbers?.sum.decimal == 30)
        #expect(tracker.currentSummary == state.summary)
    }

    @Test("unmounting the grid takes its summary down and stops it publishing again")
    func dismantleClearsAndDetaches() async {
        let state = SelectionSummaryState()
        let (coordinator, _) = makeGrid([[.text("1")], [.text("2")]], types: [Self.integer], state: state)
        let tracker = coordinator.selectionSummaryTracker
        coordinator.selectionController.update(Self.block(rows: 0...1, columns: 0...0))
        await tracker.pendingTask?.value
        #expect(state.summary != nil)

        DataGridView.dismantleNSView(NSScrollView(), coordinator: coordinator)
        coordinator.applyDelta(.cellChanged(row: 0, column: 0))
        await tracker.pendingTask?.value

        #expect(state.summary == nil)
        #expect(tracker.state == nil)
    }

    @Test("only the grid that attached last may write the summary")
    func onlyTheActiveOwnerWrites() {
        let state = SelectionSummaryState()
        let outgoing = UUID()
        let incoming = UUID()
        let summary = SelectionSummary(
            valueCount: 2,
            emptyCount: 0,
            notANumberCount: 0,
            numbers: nil,
            coversWholeColumn: false
        )

        state.activate(outgoing)
        state.publish(summary, from: outgoing)
        state.activate(incoming)
        #expect(state.summary == nil, "Attaching another grid takes the old grid's figures down")

        state.publish(summary, from: outgoing)
        #expect(state.summary == nil)

        state.publish(summary, from: incoming)
        state.clear(from: outgoing)
        state.deactivate(outgoing)
        #expect(state.summary == summary)

        state.deactivate(incoming)
        #expect(state.summary == nil)
    }

    @Test("a computation the outgoing grid finishes after the incoming grid attached is dropped")
    func outgoingCompletionNeverLandsOnTheIncomingGrid() async {
        let gate = SummaryComputeGate()
        let state = SelectionSummaryState()
        let outgoing = SelectionSummaryTracker(
            inputProvider: { Self.standaloneInput(["1", "2"]) },
            compute: { try await gate.compute($0) }
        )
        outgoing.attach(state)
        let inFlight = outgoing.pendingTask
        await gate.waitUntilEntered()

        let incoming = SelectionSummaryTracker(inputProvider: { Self.standaloneInput(["10", "20"]) })
        incoming.attach(state)
        await incoming.pendingTask?.value
        #expect(state.summary?.numbers?.sum.decimal == 30)

        await gate.open()
        await inFlight?.value

        #expect(state.summary?.numbers?.sum.decimal == 30)
        outgoing.attach(nil)
        #expect(state.summary?.numbers?.sum.decimal == 30)
    }

    @Test("figures being recomputed stay on screen but are not current, so Copy waits")
    func recomputeMarksTheFiguresPending() async {
        let state = SelectionSummaryState()
        let (coordinator, _) = makeGrid([[.text("1")], [.text("2")]], types: [Self.integer], state: state)
        let tracker = coordinator.selectionSummaryTracker
        coordinator.selectionController.update(Self.block(rows: 0...1, columns: 0...0))
        await tracker.pendingTask?.value
        #expect(state.isCurrent)

        coordinator.commitCellEdit(row: 0, columnIndex: 0, newValue: "5")
        #expect(!state.isCurrent)
        #expect(state.summary?.numbers?.sum.decimal == 3)

        await tracker.pendingTask?.value
        #expect(state.isCurrent)
        #expect(state.summary?.numbers?.sum.decimal == 7)
    }

    @Test("a display format on a summed column leaves it counted but not summed, and taking it off sums it again")
    func displayFormatChangeRecomputes() async {
        let state = SelectionSummaryState()
        let (coordinator, _) = makeGrid([[.text("1")], [.text("2")]], types: [Self.integer], state: state)
        let tracker = coordinator.selectionSummaryTracker
        coordinator.selectionController.update(Self.block(rows: 0...1, columns: 0...0))
        await tracker.pendingTask?.value
        #expect(state.summary?.numbers?.sum.decimal == 3)

        coordinator.updateDisplayFormats([.unixTimestamp])
        await tracker.pendingTask?.value
        #expect(state.summary?.numbers == nil)
        #expect(state.summary?.valueCount == 2)
        #expect(state.summary?.notANumberCount == 0)

        coordinator.updateDisplayFormats([nil])
        await tracker.pendingTask?.value
        #expect(state.summary?.numbers?.sum.decimal == 3)
    }

    @Test("a row staged for deletion leaves the sum, and Undo Delete puts it back")
    func stagedDeletionAndUndoDeleteRecompute() async {
        let state = SelectionSummaryState()
        let manager = DataChangeManager()
        let (coordinator, _) = makeGrid(
            [[.text("1")], [.text("2")], [.text("3")]],
            types: [Self.integer],
            state: state,
            changeManager: manager
        )
        let tracker = coordinator.selectionSummaryTracker
        coordinator.selectionController.update(Self.block(rows: 0...2, columns: 0...0))
        await tracker.pendingTask?.value
        #expect(state.summary?.numbers?.sum.decimal == 6)

        manager.recordRowDeletion(rowID: .existing(1), originalRow: [.text("2")])
        coordinator.invalidateCachesForUndoRedo()
        await tracker.pendingTask?.value
        #expect(state.summary?.numbers?.sum.decimal == 4)
        #expect(state.summary?.valueCount == 2)

        coordinator.undoDeleteRow(at: 1)
        await tracker.pendingTask?.value
        #expect(!manager.isRowDeleted(.existing(1)))
        #expect(state.summary?.numbers?.sum.decimal == 6)
        #expect(state.summary?.valueCount == 3)
    }
}
