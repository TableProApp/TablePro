//
//  RewindPlanner.swift
//  TablePro
//
//  Decides what a rewind would do, by looking at the rows as they stand now.
//
//  The conflict check is a read followed by a comparison in the app, not an equality test bolted
//  onto the WHERE clause. Comparing in SQL looks cheaper and is wrong twice over: a float, a
//  timestamp or a numeric that the driver round-trips with a different spelling would fail to
//  match and the row would be skipped for a formatting reason, and a row that failed to match
//  would report nothing a person could act on. Reading first costs one query and produces a plan
//  the user can read before agreeing to it.
//
//  Only the columns the save actually wrote are compared. A trigger that stamped `updated_at`
//  changed a column this save never touched, and calling that a conflict would make the feature
//  useless on exactly the tables that need it most.
//

import Foundation
import os
import TableProPluginKit

@MainActor
struct RewindPlanner {
    private static let logger = Logger(subsystem: "com.TablePro", category: "RewindPlanner")

    let record: RewindRecord
    let factory: RowChangeStatementFactory
    let queryBuilder: TableQueryBuilder

    /// The queries that read the affected rows as they stand now.
    ///
    /// Separate from `plan(currentRows:)` so the driver work is a plain list of strings in and
    /// rows out. Everything that needs the plugin registry stays on the main actor, and nothing
    /// main-actor-isolated has to cross into the driver lease.
    func readQueries() -> [String] {
        readQueries(for: record.reversibleOperations.filter(keyIsComparable))
    }

    func plan(currentRows: [RewindCurrentRow]) throws -> RewindPlan {
        let current = indexByKey(currentRows)

        var rows: [RewindRowPlan] = []
        var restorable: [RowWriteOperation] = []
        for operation in record.operations {
            if let refusal = operation.refusal {
                rows.append(
                    RewindRowPlan(
                        id: UUID(), operation: operation,
                        outcome: .notReversible(refusal), currentImage: nil
                    )
                )
                continue
            }
            guard keyIsComparable(operation) else {
                rows.append(
                    RewindRowPlan(
                        id: UUID(), operation: operation,
                        outcome: .notReversible(.keyNotComparable), currentImage: nil
                    )
                )
                continue
            }
            let key = primaryKey(of: operation)
            let currentRow = key.flatMap { current[$0] }
            let outcome = classify(operation, current: currentRow)
            rows.append(
                RewindRowPlan(id: UUID(), operation: operation, outcome: outcome, currentImage: currentRow?.values)
            )
            if outcome.restores {
                restorable.append(operation)
            }
        }

        return RewindPlan(record: record, rows: rows, statements: try statements(for: restorable))
    }

    // MARK: - Classification

    private func classify(_ operation: RowWriteOperation, current: RewindCurrentRow?) -> RewindRowOutcome {
        switch operation.kind {
        case .update:
            guard let current else { return .rowMissing }
            guard let postImage = operation.postImage, let preImage = operation.preImage else {
                return .notReversible(.serverComputedValue)
            }
            if matches(current, preImage, absent: operation.preImageAbsentColumns, on: operation) {
                return .alreadyRestored
            }
            guard matches(current, postImage, absent: operation.postImageAbsentColumns, on: operation) else {
                return .changedSinceSave
            }
            return .willRestore
        case .delete:
            if current != nil { return .rowAlreadyPresent }
            return .willRestore
        case .insert:
            guard let current else { return .alreadyRestored }
            guard let postImage = operation.postImage else { return .notReversible(.serverAssignedKey) }
            guard matches(current, postImage, absent: operation.postImageAbsentColumns, on: operation) else {
                return .changedSinceSave
            }
            return .willRestore
        }
    }

    /// Whether the row holds what the image says on every column the save wrote: the same value,
    /// and the field there or missing as it was. Set NULL on a missing field and Remove Field on a
    /// NULL one leave the value alone, so comparing values alone reads either as already restored.
    ///
    /// A record saved before absence was captured has none to compare, so it is compared on values
    /// alone, as it was then.
    private func matches(
        _ current: RewindCurrentRow,
        _ expected: [PluginCellValue],
        absent expectedAbsent: Set<Int>?,
        on operation: RowWriteOperation
    ) -> Bool {
        operation.writtenColumns.allSatisfy { column in
            guard let index = operation.columns.firstIndex(of: column),
                  index < current.values.count, index < expected.count,
                  current.values[index] == expected[index]
            else { return false }
            guard let expectedAbsent else { return true }
            return current.absentColumns.contains(index) == expectedAbsent.contains(index)
        }
    }

    // MARK: - Reading

    private func indexByKey(_ rows: [RewindCurrentRow]) -> [RewindRowKey: RewindCurrentRow] {
        let columns = record.operations.first?.columns ?? []
        let keyColumns = record.operations.first?.primaryKeyColumns ?? []
        var byKey: [RewindRowKey: RewindCurrentRow] = [:]
        for row in rows {
            guard let key = primaryKey(of: row.values, columns: columns, keyColumns: keyColumns) else { continue }
            byKey[key] = row
        }
        return byKey
    }

    /// One query for a single-column key, one per row for a composite one.
    ///
    /// `OR` over equality conditions is the only shape every engine's filter builder can express,
    /// and a composite key needs `AND` within a row, which the builder applies to the whole query.
    ///
    /// The recorded columns are projected by name rather than left to `SELECT *`, so a row read
    /// back here lines up with the images stored beside it whatever the table has done since.
    private func readQueries(for operations: [RowWriteOperation]) -> [String] {
        guard let first = operations.first else { return [] }
        let columns = first.columns
        let keyColumns = first.primaryKeyColumns
        guard !keyColumns.isEmpty else { return [] }

        if keyColumns.count == 1, let keyColumn = keyColumns.first {
            let filters = operations.compactMap { operation -> TableFilter? in
                guard let value = keyValue(of: operation, column: keyColumn) else { return nil }
                return TableFilter(columnName: keyColumn, filterOperator: .equal, value: value)
            }
            guard !filters.isEmpty else { return [] }
            return [
                queryBuilder.buildFilteredQuery(
                    tableName: record.target.table,
                    schemaName: record.target.schema,
                    filters: filters,
                    logicMode: .or,
                    columns: columns,
                    selectColumns: columns,
                    limit: filters.count
                ),
            ]
        }

        return operations.compactMap { operation in
            let filters = keyColumns.compactMap { column -> TableFilter? in
                guard let value = keyValue(of: operation, column: column) else { return nil }
                return TableFilter(columnName: column, filterOperator: .equal, value: value)
            }
            guard filters.count == keyColumns.count else { return nil }
            return queryBuilder.buildFilteredQuery(
                tableName: record.target.table,
                schemaName: record.target.schema,
                filters: filters,
                logicMode: .and,
                columns: columns,
                selectColumns: columns,
                limit: 1
            )
        }
    }

    // MARK: - Statements

    /// The inverse operations, newest first.
    ///
    /// Reverse order matters when one row in the save freed a value another row took: putting the
    /// second row's change back before the first row's is the only order that does not collide.
    /// The forward generator groups by verb, which loses that order, so the inverse is generated
    /// one operation at a time.
    private func statements(for operations: [RowWriteOperation]) throws -> [ParameterizedStatement] {
        var statements: [ParameterizedStatement] = []
        for operation in operations.reversed() {
            statements.append(contentsOf: try inverseStatements(for: operation))
        }
        return statements
    }

    private func inverseStatements(for operation: RowWriteOperation) throws -> [ParameterizedStatement] {
        switch operation.kind {
        case .update:
            guard let preImage = operation.preImage, let postImage = operation.postImage else { return [] }
            let absentBefore = operation.absentColumnsBeforeWrite
            let absentAfter = operation.absentColumnsAfterWrite
            let cellChanges = operation.writtenColumns.compactMap { column -> CellChange? in
                guard let index = operation.columns.firstIndex(of: column),
                      index < preImage.count, index < postImage.count
                else { return nil }
                return CellChange(
                    columnIndex: index, columnName: column,
                    oldValue: postImage[index], newValue: preImage[index],
                    oldIsAbsent: absentAfter.contains(index), newIsAbsent: absentBefore.contains(index)
                )
            }
            guard !cellChanges.isEmpty else { return [] }
            return try factory.statements(
                for: [RowChange(
                    rowID: .existing(0), type: .update, cellChanges: cellChanges,
                    originalRow: postImage, absentColumns: absentAfter
                )]
            )
        case .delete:
            guard let preImage = operation.preImage else { return [] }
            return try factory.restoreStatements(rows: [preImage], absentCells: [0: operation.absentColumnsBeforeWrite])
        case .insert:
            guard let postImage = operation.postImage else { return [] }
            return try factory.statements(
                for: [RowChange(rowID: .existing(0), type: .delete, cellChanges: [], originalRow: postImage)],
                deletedRowIDs: [.existing(0)]
            )
        }
    }

    // MARK: - Keys

    private func primaryKey(of operation: RowWriteOperation) -> RewindRowKey? {
        let source = operation.preImage ?? operation.postImage
        guard let source else { return nil }
        return primaryKey(of: source, columns: operation.columns, keyColumns: operation.primaryKeyColumns)
    }

    private func primaryKey(
        of row: [PluginCellValue],
        columns: [String],
        keyColumns: [String]
    ) -> RewindRowKey? {
        guard !keyColumns.isEmpty else { return nil }
        var values: [PluginCellValue] = []
        for column in keyColumns {
            guard let index = columns.firstIndex(of: column), index < row.count else { return nil }
            values.append(row[index])
        }
        return RewindRowKey(values: values)
    }

    /// Whether every key column can be written into a filter.
    ///
    /// A binary key has no text form, so no filter can name it. Without a read there is nothing to
    /// compare against, and a delete would be reported as restorable with no conflict check at all.
    private func keyIsComparable(_ operation: RowWriteOperation) -> Bool {
        !operation.primaryKeyColumns.isEmpty
            && operation.primaryKeyColumns.allSatisfy { keyValue(of: operation, column: $0) != nil }
    }

    private func keyValue(of operation: RowWriteOperation, column: String) -> String? {
        let source = operation.preImage ?? operation.postImage
        guard let source,
              let index = operation.columns.firstIndex(of: column),
              index < source.count
        else { return nil }
        return source[index].asText
    }
}

struct RewindRowKey: Hashable, Sendable {
    let values: [PluginCellValue]
}

/// A row a rewind read back, lined up with the columns its record was written against.
struct RewindCurrentRow: Sendable, Equatable {
    let values: [PluginCellValue]
    /// The recorded columns the row has no field for, which only an engine that tells a missing
    /// field from NULL reports.
    var absentColumns: Set<Int> = []

    /// A read's rows in the recorded column order.
    ///
    /// A SQL read projects the recorded columns, so its rows already line up. A document store
    /// returns the fields its documents have, in its own order, and a field none of them has is
    /// not a column at all, so with `matchingByName` each row is matched to the record by field
    /// name, and a recorded field the read did not return is one the row does not have.
    static func rows(
        of result: QueryResult,
        alignedTo columns: [String],
        matchingByName: Bool
    ) -> [RewindCurrentRow] {
        guard matchingByName, result.columns != columns else {
            return result.rows.enumerated().map { index, values in
                RewindCurrentRow(values: values, absentColumns: result.absentCells[index] ?? [])
            }
        }
        let sourceIndices = columns.map { result.columns.firstIndex(of: $0) }
        return result.rows.enumerated().map { index, values in
            let absentInResult = result.absentCells[index] ?? []
            var absent: Set<Int> = []
            let aligned = sourceIndices.enumerated().map { column, source -> PluginCellValue in
                guard let source, source < values.count else {
                    absent.insert(column)
                    return .null
                }
                if absentInResult.contains(source) { absent.insert(column) }
                return values[source]
            }
            return RewindCurrentRow(values: aligned, absentColumns: absent)
        }
    }
}
