//
//  DataFileController+Mutations.swift
//  TablePro
//

import Foundation
import os
import TableProTabular
import TableProTabularIO

struct DataFileMutationOutcome: Sendable {
    let table: TabularTable?
    let message: String?
    let removedKeys: Set<Int>

    init(table: TabularTable?, message: String?, removedKeys: Set<Int> = []) {
        self.table = table
        self.message = message
        self.removedKeys = removedKeys
    }
}

extension DataFileController {
    var canStartMutation: Bool {
        isEditable && !hasMutationInFlight
    }

    func runMutation(
        title: String,
        actionName: String,
        work: @escaping @Sendable (TabularTable, @escaping @Sendable (Double) -> Void) async throws -> DataFileMutationOutcome?
    ) {
        guard canStartMutation, let snapshot = table else { return }
        let activityID = beginActivity(title: title, isMutation: true)
        let reporter = progressReporter(for: activityID)
        let task = Task { [weak self] in
            do {
                let outcome = try await work(snapshot, reporter)
                self?.finishMutation(outcome, snapshot: snapshot, actionName: actionName, activityID: activityID)
            } catch {
                self?.abandonMutation(error: error, activityID: activityID)
            }
        }
        setMutationTask(task)
    }

    private func finishMutation(
        _ outcome: DataFileMutationOutcome?,
        snapshot: TabularTable,
        actionName: String,
        activityID: UUID
    ) {
        endActivity(activityID)
        setMutationTask(nil)
        guard let outcome else { return }
        guard let updated = outcome.table else {
            if let message = outcome.message {
                showMessage(message)
            }
            return
        }
        guard let current = table, current.generation == snapshot.generation else {
            showMessage(String(localized: "The file changed while the operation ran, so nothing was applied."))
            return
        }
        let removed = outcome.removedKeys
        let newDisplay = removed.isEmpty ? displayKeys : displayKeys.map { $0.filter { !removed.contains($0) } }
        commit(updated, actionName: actionName, displayKeys: .some(newDisplay))
        if let message = outcome.message {
            showMessage(message)
        }
        if find.isVisible, find.hasQuery {
            runFind()
        }
    }

    private func abandonMutation(error: Error, activityID: UUID) {
        endActivity(activityID)
        setMutationTask(nil)
        guard !error.isDataFileCancellation else { return }
        Self.logger.error("Data file operation failed: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
        showMessage(error.localizedDescription)
    }

    nonisolated static func applying(_ values: [TabularColumnID: ColumnValues], to table: TabularTable) -> TabularTable {
        var updated = table
        for (id, columnValues) in values {
            updated.replaceValues(of: id, with: columnValues)
        }
        return updated
    }

    func splitColumn(_ id: TabularColumnID, separator: TabularSplitSeparator) {
        guard let baseName = columnNames.name(for: id) else { return }
        runMutation(title: String(localized: "Splitting Column…"), actionName: String(localized: "Split Column")) { table, progress in
            let pieces = try await TabularColumnSplit.split(column: id, by: separator, in: table, progress: progress)
            guard pieces.count > 1, let index = table.columnIndex(of: id) else {
                return DataFileMutationOutcome(table: nil, message: String(localized: "No values contain the separator."))
            }
            var updated = table
            for (offset, values) in pieces.enumerated() {
                updated.insertColumn(named: "\(baseName) \(offset + 1)", at: index + 1 + offset, values: values)
            }
            updated.deleteColumns([id])
            return DataFileMutationOutcome(table: updated, message: nil)
        }
    }

    func mergeColumn(_ left: TabularColumnID, with right: TabularColumnID, separator: String) {
        runMutation(title: String(localized: "Merging Columns…"), actionName: String(localized: "Merge Columns")) { table, progress in
            let merged = try await TabularColumnSplit.merge(left, with: right, separator: separator, in: table, progress: progress)
            var updated = table
            updated.replaceValues(of: left, with: merged)
            updated.deleteColumns([right])
            return DataFileMutationOutcome(table: updated, message: nil)
        }
    }

    func applyCleanup(_ operation: TabularCleanupOperation, columns: [TabularColumnID], keys: [Int], actionName: String) {
        guard !columns.isEmpty, !keys.isEmpty else { return }
        runMutation(title: String(localized: "Updating Cells…"), actionName: actionName) { table, progress in
            let result = try await TabularCleanup.apply(operation, columns: columns, keys: keys, in: table, progress: progress)
            guard result.changedCells > 0 else {
                return DataFileMutationOutcome(table: nil, message: String(localized: "No cells changed."))
            }
            return DataFileMutationOutcome(
                table: Self.applying(result.values, to: table),
                message: Self.changedCellsMessage(result.changedCells)
            )
        }
    }

    nonisolated static func changedCellsMessage(_ count: Int) -> String {
        String(format: String(localized: "Changed %@."), DataFileCountPhrase.cells(count))
    }
}
