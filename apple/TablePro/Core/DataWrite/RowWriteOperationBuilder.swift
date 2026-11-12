//
//  RowWriteOperationBuilder.swift
//  TablePro
//
//  Turns the pending change set into the record of what each row looked like before and after.
//
//  This runs at plan time, before the write, because after the write the pre-image is gone. It
//  is also where a row is declared beyond rescue: a column set to SQL such as now(), a key the server is
//  about to choose, a value too large to keep. Deciding that here means the review sheet can say
//  why a row cannot be restored instead of failing at the moment someone asks it to.
//

import Foundation
import TableProPluginKit

enum RowWriteOperationBuilder {
    /// A single value larger than this is not captured.
    ///
    /// The store holds production rows, so it needs a ceiling that does not depend on the user
    /// noticing. `TabQueryContent.maxPersistableQuerySize` is the same idea for tab persistence.
    static let maximumCapturedValueBytes = 1_048_576

    static func operations(
        from changes: [RowChange],
        insertedRowData: [RowID: [PluginCellValue]],
        deletedRowIDs: Set<RowID>,
        insertedRowIDs: Set<RowID>,
        target: DataWriteTarget,
        columns: [String],
        primaryKeyColumns: [String],
        generatedColumns: Set<String>,
        containsTableOperation: Bool,
        rowsWithUnloadedValues: Set<RowID> = [],
        writesThroughView: Bool = false,
        rowLocators: [RowID: String] = [:]
    ) -> [RowWriteOperation] {
        // The same steps the save runs, so the record matches what ran.
        let keyColumns = Set(primaryKeyColumns.compactMap { columns.firstIndex(of: $0) })
        var stepsByRow: [RowID: [RowChange]] = [:]
        for step in RowChange.saveSteps(changes, keyColumns: keyColumns) where step.type == .update {
            stepsByRow[step.rowID, default: []].append(step)
        }
        func firstOrder(of change: RowChange) -> Int {
            guard change.type == .update else { return change.sequence }
            return stepsByRow[change.rowID]?.first?.sequence ?? change.sequence
        }

        // A rewind undoes them newest first, and `changes` stops being in edit order once a change is cancelled.
        let ordered = changes.enumerated()
            .sorted { (firstOrder(of: $0.element), $0.offset) < (firstOrder(of: $1.element), $1.offset) }
            .map(\.element)
        return ordered.compactMap { change -> RowWriteOperation? in
            var operation: RowWriteOperation
            switch change.type {
            case .update:
                let steps = stepsByRow[change.rowID] ?? [change]
                operation = update(
                    change, steps: steps, target: target, columns: columns,
                    primaryKeyColumns: primaryKeyColumns, generatedColumns: generatedColumns,
                    containsTableOperation: containsTableOperation
                )
                operation.rowLocator = rowLocators[change.rowID]
                operation.steps = steps.count > 1 ? steps.map { RowWriteStep($0) } : nil
            case .delete:
                guard deletedRowIDs.contains(change.rowID) else { return nil }
                operation = delete(
                    change, target: target, columns: columns,
                    primaryKeyColumns: primaryKeyColumns,
                    containsTableOperation: containsTableOperation,
                    hasUnloadedValues: rowsWithUnloadedValues.contains(change.rowID),
                    throughView: writesThroughView
                )
                operation.rowLocator = rowLocators[change.rowID]
            case .insert:
                guard insertedRowIDs.contains(change.rowID) else { return nil }
                operation = insert(
                    change, values: insertedRowData[change.rowID],
                    target: target, columns: columns,
                    primaryKeyColumns: primaryKeyColumns,
                    containsTableOperation: containsTableOperation
                )
            }
            operation.order = firstOrder(of: change)
            return operation
        }
    }

    private static func update(
        _ change: RowChange,
        steps: [RowChange],
        target: DataWriteTarget,
        columns: [String],
        primaryKeyColumns: [String],
        generatedColumns: Set<String>,
        containsTableOperation: Bool
    ) -> RowWriteOperation {
        let writtenColumns = change.cellChanges.map(\.columnName)
        let preImage = change.originalRow
        let postImage = preImage.map { row in
            var updated = row
            for cellChange in change.cellChanges where cellChange.columnIndex < updated.count {
                updated[cellChange.columnIndex] = cellChange.newValue
            }
            return updated
        }

        return RowWriteOperation(
            kind: .update,
            target: target,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            preImage: preImage,
            postImage: postImage,
            writtenColumns: writtenColumns,
            refusal: updateRefusal(
                writing: change.cellChanges + steps.flatMap(\.cellChanges), preImage: preImage,
                primaryKeyColumns: primaryKeyColumns, generatedColumns: generatedColumns,
                containsTableOperation: containsTableOperation
            ),
            preImageAbsentColumns: change.absentColumns,
            postImageAbsentColumns: change.absentColumnsAfterUpdate
        )
    }

    // Every step's cells count: the inverse of a later step would write an earlier step's SQL back as a literal.
    private static func updateRefusal(
        writing cellChanges: [CellChange],
        preImage: [PluginCellValue]?,
        primaryKeyColumns: [String],
        generatedColumns: Set<String>,
        containsTableOperation: Bool
    ) -> RewindRefusal? {
        if containsTableOperation { return .destructiveTableOperation }
        if primaryKeyColumns.isEmpty || preImage == nil { return .noPrimaryKey }
        if cellChanges.contains(where: \.newIsExpression) {
            return .serverComputedValue
        }
        if cellChanges.contains(where: { generatedColumns.contains($0.columnName) }) {
            return .serverComputedValue
        }
        if let preImage, preImage.contains(where: exceedsCapture) { return .valueTooLarge }
        if cellChanges.contains(where: { exceedsCapture($0.newValue) }) { return .valueTooLarge }
        return nil
    }

    private static func delete(
        _ change: RowChange,
        target: DataWriteTarget,
        columns: [String],
        primaryKeyColumns: [String],
        containsTableOperation: Bool,
        hasUnloadedValues: Bool,
        throughView: Bool
    ) -> RowWriteOperation {
        let refusal: RewindRefusal? = {
            if containsTableOperation { return .destructiveTableOperation }
            // A case every shipped build can read, so one that predates the view flag still refuses.
            if throughView { return .identityNotPreservable }
            guard let originalRow = change.originalRow else { return .noPrimaryKey }
            if primaryKeyColumns.isEmpty { return .noPrimaryKey }
            // A value the page left on the server was larger than the inline limit and never read.
            if hasUnloadedValues || originalRow.contains(where: exceedsCapture) { return .valueTooLarge }
            return nil
        }()

        return RowWriteOperation(
            kind: .delete,
            target: target,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            preImage: change.originalRow,
            postImage: nil,
            writtenColumns: columns,
            refusal: refusal,
            preImageAbsentColumns: change.absentColumns
        )
    }

    private static func insert(
        _ change: RowChange,
        values: [PluginCellValue]?,
        target: DataWriteTarget,
        columns: [String],
        primaryKeyColumns: [String],
        containsTableOperation: Bool
    ) -> RowWriteOperation {
        let refusal: RewindRefusal? = {
            if containsTableOperation { return .destructiveTableOperation }
            if primaryKeyColumns.isEmpty { return .noPrimaryKey }
            guard let values else { return .serverAssignedKey }
            for keyColumn in primaryKeyColumns {
                guard let index = columns.firstIndex(of: keyColumn), index < values.count else {
                    return .serverAssignedKey
                }
                let value = values[index]
                if value.isNull || change.expressionColumns.contains(index) {
                    return .serverAssignedKey
                }
            }
            if !change.expressionColumns.isEmpty {
                return .serverComputedValue
            }
            if values.contains(where: exceedsCapture) { return .valueTooLarge }
            return nil
        }()

        return RowWriteOperation(
            kind: .insert,
            target: target,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            preImage: nil,
            postImage: values,
            writtenColumns: columns,
            refusal: refusal,
            postImageAbsentColumns: change.absentColumns
        )
    }

    private static func exceedsCapture(_ value: PluginCellValue) -> Bool {
        switch value {
        case .null:
            return false
        case .text(let text):
            return text.utf8.count > maximumCapturedValueBytes
        case .bytes(let data):
            return data.count > maximumCapturedValueBytes
        }
    }
}
