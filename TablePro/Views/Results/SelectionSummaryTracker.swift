//
//  SelectionSummaryTracker.swift
//  TablePro
//

import Foundation

@MainActor
final class SelectionSummaryTracker {
    typealias Compute = @Sendable (SelectionSummaryInput) async throws -> SelectionSummary

    let owner = UUID()
    private(set) var state: SelectionSummaryState?
    private(set) var currentSummary: SelectionSummary?
    var pendingTask: Task<Void, Never>?

    private let inputProvider: @MainActor () -> SelectionSummaryInput?
    private let compute: Compute
    private var generation = 0
    private var isRecomputeScheduled = false

    init(
        inputProvider: @escaping @MainActor () -> SelectionSummaryInput?,
        compute: @escaping Compute = { try await SelectionSummaryCalculator.shared.summarize($0) }
    ) {
        self.inputProvider = inputProvider
        self.compute = compute
    }

    func attach(_ newState: SelectionSummaryState?) {
        guard newState !== state else { return }
        state?.deactivate(owner)
        state = newState
        newState?.activate(owner)
        scheduleRecompute()
    }

    func selectionDidChange() {
        scheduleRecompute()
    }

    func dataDidChange() {
        scheduleRecompute()
    }

    func rulesDidChange() {
        scheduleRecompute()
    }

    func cancel() {
        generation &+= 1
        isRecomputeScheduled = false
        pendingTask?.cancel()
        pendingTask = nil
        currentSummary = nil
    }

    /// A drag reports every step and a paste every cell, so the calls of one turn share one run.
    private func scheduleRecompute() {
        guard state != nil else {
            cancel()
            return
        }
        generation &+= 1
        currentSummary = nil
        state?.markPending(from: owner)
        guard !isRecomputeScheduled else { return }
        isRecomputeScheduled = true
        pendingTask?.cancel()
        pendingTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            self.isRecomputeScheduled = false
            await self.recompute()
        }
    }

    private func recompute() async {
        guard let state, let input = inputProvider() else {
            currentSummary = nil
            state?.clear(from: owner)
            return
        }
        let expected = generation
        guard let summary = try? await compute(input),
              !Task.isCancelled,
              generation == expected else { return }
        currentSummary = summary
        state.publish(summary, from: owner)
    }
}

internal extension TableViewCoordinator {
    /// Nil while fewer than two cells are selected, which is when the grid reports no summary.
    func selectionSummaryInput() -> SelectionSummaryInput? {
        let selection = selectionController.selection
        guard selection.hasMultipleCells else { return nil }
        let tableRows = tableRowsProvider()
        let policy = delegate?.dataGridSummaryColumnPolicy() ?? .derived(
            columnTypes: tableRows.columnTypes,
            displayFormats: columnDisplayFormats,
            columnCount: tableRows.columns.count
        )
        return SelectionSummaryInput(
            selection: selection,
            tableRows: tableRows,
            displayIDs: displayIDs,
            dataColumnsByDisplayPosition: presentedDataColumns,
            policy: policy,
            deletedRowIDs: changeManager.deletedRowIDs,
            insertedRowIDs: changeManager.insertedRowIDs,
            modifiedCells: changeManager.modifiedCells
        )
    }
}
