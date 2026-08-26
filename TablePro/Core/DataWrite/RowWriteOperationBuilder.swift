//
//  RowWriteOperationBuilder.swift
//  TablePro
//
//  Turns the pending change set into the record of what each row looked like before and after.
//
//  This runs at plan time, before the write, because after the write the pre-image is gone. It
//  is also where a row is declared beyond rescue: a column set to NOW(), a key the server is
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
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>,
        target: DataWriteTarget,
        columns: [String],
        primaryKeyColumns: [String],
        generatedColumns: Set<String>,
        containsTableOperation: Bool
    ) -> [RowWriteOperation] {
        changes.compactMap { change in
            switch change.type {
            case .update:
                return update(
                    change, target: target, columns: columns,
                    primaryKeyColumns: primaryKeyColumns, generatedColumns: generatedColumns,
                    containsTableOperation: containsTableOperation
                )
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { return nil }
                return delete(
                    change, target: target, columns: columns,
                    primaryKeyColumns: primaryKeyColumns,
                    containsTableOperation: containsTableOperation
                )
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex) else { return nil }
                return insert(
                    change, values: insertedRowData[change.rowIndex],
                    target: target, columns: columns,
                    primaryKeyColumns: primaryKeyColumns,
                    containsTableOperation: containsTableOperation
                )
            }
        }
    }

    private static func update(
        _ change: RowChange,
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
                change, preImage: preImage, primaryKeyColumns: primaryKeyColumns,
                generatedColumns: generatedColumns, containsTableOperation: containsTableOperation
            )
        )
    }

    private static func updateRefusal(
        _ change: RowChange,
        preImage: [PluginCellValue]?,
        primaryKeyColumns: [String],
        generatedColumns: Set<String>,
        containsTableOperation: Bool
    ) -> RewindRefusal? {
        if containsTableOperation { return .destructiveTableOperation }
        if primaryKeyColumns.isEmpty || preImage == nil { return .noPrimaryKey }
        if change.cellChanges.contains(where: { isServerComputed($0.newValue) }) { return .serverComputedValue }
        if change.cellChanges.contains(where: { generatedColumns.contains($0.columnName) }) {
            return .serverComputedValue
        }
        if let preImage, preImage.contains(where: exceedsCapture) { return .valueTooLarge }
        if change.cellChanges.contains(where: { exceedsCapture($0.newValue) }) { return .valueTooLarge }
        return nil
    }

    private static func delete(
        _ change: RowChange,
        target: DataWriteTarget,
        columns: [String],
        primaryKeyColumns: [String],
        containsTableOperation: Bool
    ) -> RowWriteOperation {
        let refusal: RewindRefusal? = {
            if containsTableOperation { return .destructiveTableOperation }
            guard let originalRow = change.originalRow else { return .noPrimaryKey }
            if primaryKeyColumns.isEmpty { return .noPrimaryKey }
            if originalRow.contains(where: exceedsCapture) { return .valueTooLarge }
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
            refusal: refusal
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
                if value.isNull || value.isDefaultMarker { return .serverAssignedKey }
            }
            if values.contains(where: isServerComputed) { return .serverComputedValue }
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
            refusal: refusal
        )
    }

    /// A value the server decides, so the app never learns what was actually stored.
    private static func isServerComputed(_ value: PluginCellValue) -> Bool {
        if value.isDefaultMarker { return true }
        guard case .text(let text) = value else { return false }
        return SQLEscaping.isTemporalFunction(text)
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
