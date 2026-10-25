import AppKit
import Foundation
@testable import TablePro
import TableProNumberFormatting
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
private final class SummaryInputBox {
    var input: SelectionSummaryInput?

    init(_ input: SelectionSummaryInput?) {
        self.input = input
    }
}

// Holds the first computation open until the test lets it go, after it has its result.
private actor SummaryComputeGate {
    private var callCount = 0
    private let entered = AsyncGate()
    private let release = AsyncGate()

    func compute(_ input: SelectionSummaryInput) async throws -> SelectionSummary {
        callCount += 1
        let isFirst = callCount == 1
        let summary = try await SelectionSummaryCalculator().summarize(input)
        guard isFirst else { return summary }
        await entered.open()
        await release.wait()
        return summary
    }

    func waitUntilEntered() async {
        await entered.wait()
    }

    func open() async {
        await release.open()
    }
}

// A mounted grid whose model publishes into a summary state, which the shared fixture's model does not take.
@MainActor
private final class SummaryGrid {
    let owner: GridTestOwner
    let model: DataGridModel
    let controller: DataGridViewController
    let state: SelectionSummaryState?
    private let window: NSWindow

    init(
        _ rows: [[PluginCellValue]],
        types: [ColumnType],
        state: SelectionSummaryState?,
        changeManager: DataChangeManager = DataChangeManager()
    ) {
        self.state = state
        owner = GridTestOwner(
            TableRows.from(queryRows: rows, columns: types.indices.map { "c\($0)" }, columnTypes: types),
            changeManager: changeManager
        )
        owner.appliesCommits = true
        var configuration = DataGridConfiguration()
        configuration.isEditable = true
        model = DataGridModel(configuration: configuration, selectionSummary: state)
        model.dataSource = owner
        model.actions = owner
        owner.model = model
        model.reloadRows()

        controller = DataGridViewController(model: model)
        let frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: frame)
        window.contentView = content
        controller.view.frame = content.bounds
        content.addSubview(controller.view)
    }

    var tracker: SelectionSummaryTracker { controller.selectionSummaryTracker }

    // The controller attaches its tracker on the turn after it mounts.
    func attached() async throws {
        try await waitUntil { self.tracker.state === self.state }
    }

    func edit(row: Int, to value: DataGridEditValue) {
        model.commit(
            [DataGridCellEdit(rowID: .existing(row), columnID: DataGridColumnID(name: "c0", occurrence: 0), value: value)],
            actionName: "Edit Cell"
        )
    }

    func close() {
        controller.dismantle()
        window.orderOut(nil)
    }
}

@MainActor
struct SelectionSummaryTrackerTests {
    private static let integer = ColumnType.integer(rawType: "INT")

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

    private func makeGrid(
        _ rows: [[PluginCellValue]] = [[.text("1")], [.text("2")]],
        types: [ColumnType] = [ColumnType.integer(rawType: "INT")],
        changeManager: DataChangeManager = DataChangeManager()
    ) async throws -> (SummaryGrid, SelectionSummaryState) {
        let state = SelectionSummaryState()
        let grid = SummaryGrid(rows, types: types, state: state, changeManager: changeManager)
        try await grid.attached()
        await grid.tracker.pendingTask?.value
        return (grid, state)
    }

    @Test("Widening a selection sideways recomputes, though the selected rows stay the same")
    func horizontalWideningRecomputes() async throws {
        let (grid, state) = try await makeGrid(
            [[.text("1"), .text("10")], [.text("2"), .text("20")]],
            types: [Self.integer, Self.integer]
        )
        defer { grid.close() }

        grid.model.setSelection(Self.block(rows: 0...1, columns: 0...0))
        await grid.tracker.pendingTask?.value
        #expect(state.summary?.numbers?.sum.decimal == 3)
        let narrow = state.summary

        grid.model.setSelection(Self.block(rows: 0...1, columns: 0...1))
        #expect(state.summary == narrow)
        #expect(grid.tracker.currentSummary == nil)
        await grid.tracker.pendingTask?.value

        #expect(state.summary?.numbers?.sum.decimal == 33)
        #expect(state.summary?.valueCount == 4)
        #expect(grid.tracker.currentSummary == state.summary)
    }

    @Test("An edit inside the selection recomputes the summary")
    func editInsideSelectionRecomputes() async throws {
        let (grid, state) = try await makeGrid()
        defer { grid.close() }
        grid.model.setSelection(Self.block(rows: 0...1, columns: 0...0))
        await grid.tracker.pendingTask?.value
        #expect(state.summary?.numbers?.sum.decimal == 3)

        grid.edit(row: 0, to: .enteredText("5"))
        await grid.tracker.pendingTask?.value

        #expect(state.summary?.numbers?.sum.decimal == 7)
    }

    @Test("A cell set to Default by an edit counts as empty, not as text")
    func stagedDefaultIsEmpty() async throws {
        let (grid, state) = try await makeGrid()
        defer { grid.close() }
        grid.model.setSelection(Self.block(rows: 0...1, columns: 0...0))

        grid.edit(row: 1, to: .value(.text(PluginCellValue.defaultMarkerText), isExpression: false))
        await grid.tracker.pendingTask?.value

        #expect(state.summary?.emptyCount == 1)
        #expect(state.summary?.notANumberCount == 0)
        #expect(state.summary?.numbers?.sum.decimal == 1)
    }

    @Test("Narrowing to a single cell takes the summary down")
    func singleCellClears() async throws {
        let (grid, state) = try await makeGrid()
        defer { grid.close() }
        grid.model.setSelection(Self.block(rows: 0...1, columns: 0...0))
        await grid.tracker.pendingTask?.value
        #expect(state.summary != nil)

        grid.model.setSelection(Self.block(rows: 1...1, columns: 0...0))
        await grid.tracker.pendingTask?.value

        #expect(state.summary == nil)
        #expect(grid.tracker.currentSummary == nil)
    }

    @Test("A grid with no summary state computes nothing")
    func gridWithoutStateComputesNothing() {
        let grid = SummaryGrid([[.text("1")], [.text("2")]], types: [Self.integer], state: nil)
        defer { grid.close() }

        grid.model.setSelection(Self.block(rows: 0...1, columns: 0...0))

        #expect(grid.tracker.pendingTask == nil)
        #expect(grid.tracker.currentSummary == nil)
    }

    @Test("A result computed for an older selection is never published")
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

    @Test("Unmounting the grid takes its summary down and stops it publishing again")
    func dismantleClearsAndDetaches() async throws {
        let (grid, state) = try await makeGrid()
        grid.model.setSelection(Self.block(rows: 0...1, columns: 0...0))
        await grid.tracker.pendingTask?.value
        #expect(state.summary != nil)

        grid.close()
        grid.model.apply(.cellChanged(row: 0, column: 0))
        await grid.tracker.pendingTask?.value

        #expect(state.summary == nil)
        #expect(grid.tracker.state == nil)
    }

    @Test("Only the grid that attached last may write the summary")
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

    @Test("A computation the outgoing grid finishes after the incoming grid attached is dropped")
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

    @Test("Figures being recomputed stay on screen but are not current, so Copy waits")
    func recomputeMarksTheFiguresPending() async throws {
        let (grid, state) = try await makeGrid()
        defer { grid.close() }
        grid.model.setSelection(Self.block(rows: 0...1, columns: 0...0))
        await grid.tracker.pendingTask?.value
        #expect(state.isCurrent)

        grid.edit(row: 0, to: .enteredText("5"))
        #expect(!state.isCurrent)
        #expect(state.summary?.numbers?.sum.decimal == 3)

        await grid.tracker.pendingTask?.value
        #expect(state.isCurrent)
        #expect(state.summary?.numbers?.sum.decimal == 7)
    }

    @Test("A display format on a summed column leaves it counted but not summed, and taking it off sums it again")
    func displayFormatChangeRecomputes() async throws {
        let (grid, state) = try await makeGrid()
        defer { grid.close() }
        let column = try #require(grid.model.columns.column(at: 0))
        grid.model.setSelection(Self.block(rows: 0...1, columns: 0...0))
        await grid.tracker.pendingTask?.value
        #expect(state.summary?.numbers?.sum.decimal == 3)

        grid.model.setDisplayFormat(.unixTimestamp, for: column)
        await grid.tracker.pendingTask?.value
        #expect(state.summary?.numbers == nil)
        #expect(state.summary?.valueCount == 2)
        #expect(state.summary?.notANumberCount == 0)

        grid.model.setDisplayFormat(nil, for: column)
        await grid.tracker.pendingTask?.value
        #expect(state.summary?.numbers?.sum.decimal == 3)
    }

    @Test("A row staged for deletion leaves the sum, and undoing the delete puts it back")
    func stagedDeletionAndUndoDeleteRecompute() async throws {
        let manager = DataChangeManager()
        let (grid, state) = try await makeGrid([[.text("1")], [.text("2")], [.text("3")]], changeManager: manager)
        defer { grid.close() }
        grid.model.setSelection(Self.block(rows: 0...2, columns: 0...0))
        await grid.tracker.pendingTask?.value
        #expect(state.summary?.numbers?.sum.decimal == 6)

        manager.recordRowDeletion(rowID: .existing(1), originalRow: [.text("2")])
        grid.model.repaintRows([RowID.existing(1)])
        await grid.tracker.pendingTask?.value
        #expect(state.summary?.numbers?.sum.decimal == 4)
        #expect(state.summary?.valueCount == 2)

        manager.undoRowDeletion(rowID: .existing(1))
        grid.model.repaintRows([RowID.existing(1)])
        await grid.tracker.pendingTask?.value
        #expect(!manager.isRowDeleted(.existing(1)))
        #expect(state.summary?.numbers?.sum.decimal == 6)
        #expect(state.summary?.valueCount == 3)
    }
}
