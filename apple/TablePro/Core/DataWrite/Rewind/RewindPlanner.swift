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
        let comparable = record.reversibleOperations.filter(keyIsComparable)
        guard let located = locatorQuery() else { return readQueries(for: comparable) }
        return [located] + readQueries(for: comparable.filter { $0.rowLocator == nil })
    }

    // The rows recorded with a locator, read by it, so a row whose key reads the same text is never read in its place.
    private func locatorQuery() -> String? {
        let locators = record.reversibleOperations.filter(keyIsComparable).compactMap(\.rowLocator)
        guard !locators.isEmpty else { return nil }
        return factory.pluginDriver?.buildLocatorQuery(
            table: record.target.table,
            schema: record.target.schema,
            locators: locators,
            columns: record.operations.first?.columns ?? []
        )
    }

    func plan(currentRows: [RewindCurrentRow]) throws -> RewindPlan {
        let current = indexByKey(currentRows)
        let byLocator = indexByLocator(currentRows)
        let matchesByLocator = locatorQuery() != nil || !byLocator.isEmpty

        var found: [FoundRow] = record.operations.map { operation in
            if let refusal = record.refusal(of: operation) {
                return FoundRow(outcome: .notReversible(refusal), current: nil)
            }
            guard keyIsComparable(operation) else {
                return FoundRow(outcome: .notReversible(.keyNotComparable), current: nil)
            }
            let currentRow: RewindCurrentRow?
            if let locator = operation.rowLocator, matchesByLocator {
                currentRow = byLocator[Array(locator.utf8)]
            } else {
                currentRow = primaryKey(of: operation).flatMap { current[$0] }
                    ?? rowRestoredUnderKeyBefore(operation, in: current)
            }
            return FoundRow(outcome: classify(operation, current: currentRow), current: currentRow)
        }
        restoreDeletesWhoseKeyAnInsertFrees(&found)

        var rows: [RewindRowPlan] = []
        var restorable: [RowWriteOperation] = []
        for (operation, row) in zip(record.operations, found) {
            rows.append(
                RewindRowPlan(id: UUID(), operation: operation, outcome: row.outcome, currentImage: row.current?.values)
            )
            if row.outcome.restores {
                restorable.append(operation)
            }
        }

        let inverse = try statements(for: restorable)
        return RewindPlan(
            record: record,
            rows: rows,
            statements: inverse.statements,
            lookups: inverse.lookups,
            prologue: inverse.prologue,
            epilogue: inverse.epilogue
        )
    }

    // MARK: - Classification

    private struct FoundRow {
        var outcome: RewindRowOutcome
        var current: RewindCurrentRow?
    }

    // A new row that took a deleted row's key is removed before the deleted row is put back, so that key is free.
    private func restoreDeletesWhoseKeyAnInsertFrees(_ found: inout [FoundRow]) {
        var rank: [Int: Int] = [:]
        for (position, entry) in Self.runOrder(of: record.operations).enumerated() where rank[entry.operation] == nil {
            rank[entry.operation] = position
        }
        let operations = record.operations
        for (index, delete) in operations.enumerated()
        where delete.kind == .delete && found[index].outcome == .rowAlreadyPresent {
            guard let key = primaryKey(of: delete),
                  let occupant = found[index].current,
                  primaryKey(of: occupant.values, columns: delete.columns, keyColumns: delete.primaryKeyColumns) == key,
                  let deleteRank = rank[index]
            else { continue }
            let freed = operations.indices.contains { other in
                operations[other].kind == .insert && found[other].outcome == .willRestore
                    && primaryKey(of: operations[other]) == key
                    && (rank[other] ?? .max) < deleteRank
            }
            if freed {
                found[index] = FoundRow(outcome: .willRestore, current: nil)
            }
        }
    }

    private var readsThroughView: Bool { record.writtenThroughView == true }

    private func classify(_ operation: RowWriteOperation, current: RewindCurrentRow?) -> RewindRowOutcome {
        switch operation.kind {
        case .update:
            guard let current else { return readsThroughView ? .notReversible(.rowLeftView) : .rowMissing }
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
            // Read back through a view, a row its filter no longer shows is still in the table.
            guard let current else { return readsThroughView ? .notReversible(.rowLeftView) : .alreadyRestored }
            guard let postImage = operation.postImage else { return .notReversible(.serverAssignedKey) }
            guard matches(current, postImage, absent: operation.postImageAbsentColumns, on: operation) else {
                return .changedSinceSave
            }
            return .willRestore
        }
    }

    /// Whether the row holds what the image says on every compared column: the same value,
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
        comparedColumns(of: operation).allSatisfy { column in
            guard let index = operation.columns.firstIndex(of: column),
                  index < current.values.count, index < expected.count,
                  current.values[index] == expected[index]
            else { return false }
            guard let expectedAbsent else { return true }
            return current.absentColumns.contains(index) == expectedAbsent.contains(index)
        }
    }

    // A row found by a key the save wrote holds that key whatever row it is, so a moved row is compared on every
    // column the server does not compute; a trigger's stamp then reads as changed, which leaves the row alone.
    private func comparedColumns(of operation: RowWriteOperation) -> [String] {
        guard keyBeforeMove(of: operation) != nil else { return operation.writtenColumns }
        let generated = Set(record.generatedColumns)
        return operation.columns.filter { !generated.contains($0) }
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

    // Keyed by bytes: String equality treats two Unicode spellings as one, and the server does not.
    private func indexByLocator(_ rows: [RewindCurrentRow]) -> [[UInt8]: RewindCurrentRow] {
        var byLocator: [[UInt8]: RewindCurrentRow] = [:]
        for row in rows {
            guard let locator = row.locator else { continue }
            byLocator[Array(locator.utf8)] = row
        }
        return byLocator
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
            let filters = operations.flatMap { operation in
                readImages(of: operation).compactMap { image -> TableFilter? in
                    guard let value = keyValue(in: image, of: operation, column: keyColumn) else { return nil }
                    return TableFilter(columnName: keyColumn, filterOperator: .equal, value: value)
                }
            }
            guard !filters.isEmpty,
                  let query = queryBuilder.buildFilteredQuery(
                      tableName: record.target.table,
                      schemaName: record.target.schema,
                      filters: filters,
                      logicMode: .or,
                      columns: columns,
                      selectColumns: columns,
                      limit: filters.count
                  ) else { return [] }
            return [query]
        }

        return operations.flatMap { operation in
            readImages(of: operation).compactMap { image -> String? in
                let filters = keyColumns.compactMap { column -> TableFilter? in
                    guard let value = keyValue(in: image, of: operation, column: column) else { return nil }
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
    }

    // MARK: - Statements

    struct RunEntry: Hashable {
        let operation: Int
        let step: Int?
    }

    // Newest first, step by step, since a value one write freed may be one a later write took. Ties, and a record
    // saved before orders were kept, run by list position, the later first.
    static func runOrder(of operations: [RowWriteOperation]) -> [RunEntry] {
        var entries: [(order: Int?, entry: RunEntry)] = []
        for (index, operation) in operations.enumerated() {
            if let steps = operation.steps, !steps.isEmpty {
                for (stepIndex, step) in steps.enumerated() {
                    entries.append((step.order, RunEntry(operation: index, step: stepIndex)))
                }
            } else {
                entries.append((operation.order, RunEntry(operation: index, step: nil)))
            }
        }
        return entries.sorted { lhs, rhs in
            (lhs.order ?? .min, lhs.entry.operation, lhs.entry.step ?? 0)
                > (rhs.order ?? .min, rhs.entry.operation, rhs.entry.step ?? 0)
        }.map(\.entry)
    }

    private func statements(for operations: [RowWriteOperation]) throws -> RestoreStatements {
        var statements: [ParameterizedStatement] = []
        var lookups: [RowLookup?] = []
        var prologue: [String] = []
        var epilogue: [String] = []
        for entry in Self.runOrder(of: operations) {
            let operation = operations[entry.operation]
            let inverse: RestoreStatements
            if let step = entry.step {
                inverse = try inverseStatements(for: operation, step: step)
            } else {
                inverse = try inverseStatements(for: operation)
            }
            statements.append(contentsOf: inverse.statements)
            lookups.append(contentsOf: inverse.lookups)
            prologue.append(contentsOf: inverse.prologue.filter { !prologue.contains($0) })
            epilogue.append(contentsOf: inverse.epilogue.filter { !epilogue.contains($0) })
        }
        return RestoreStatements(statements: statements, lookups: lookups, prologue: prologue, epilogue: epilogue)
    }

    // Sets the step's columns back, keyed on the row as that step left it.
    private func inverseStatements(for operation: RowWriteOperation, step index: Int) throws -> RestoreStatements {
        guard let image = operation.stepImages()?[safe: index] else { return RestoreStatements(statements: []) }
        var factory = factory
        factory.rowLocators = operation.rowLocator.map { [.existing(0): $0] } ?? [:]
        let step = image.step
        let cellChanges = step.columns.enumerated().compactMap { offset, column -> CellChange? in
            guard operation.columns.indices.contains(column), image.after.indices.contains(column),
                  step.before.indices.contains(offset)
            else { return nil }
            return CellChange(
                columnIndex: column, columnName: operation.columns[column],
                oldValue: image.after[column], newValue: step.before[offset],
                oldIsAbsent: image.absentAfter.contains(column), newIsAbsent: step.beforeAbsent.contains(column)
            )
        }
        guard !cellChanges.isEmpty else { return RestoreStatements(statements: []) }
        return try factory.lookedUpStatements(
            for: [RowChange(
                rowID: .existing(0), type: .update, cellChanges: cellChanges,
                originalRow: image.after, absentColumns: image.absentAfter
            )]
        )
    }

    private func inverseStatements(for operation: RowWriteOperation) throws -> RestoreStatements {
        var factory = factory
        factory.rowLocators = operation.rowLocator.map { [.existing(0): $0] } ?? [:]
        switch operation.kind {
        case .update:
            guard let preImage = operation.preImage, let postImage = operation.postImage else {
                return RestoreStatements(statements: [])
            }
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
            guard !cellChanges.isEmpty else { return RestoreStatements(statements: []) }
            return try factory.lookedUpStatements(
                for: [RowChange(
                    rowID: .existing(0), type: .update, cellChanges: cellChanges,
                    originalRow: postImage, absentColumns: absentAfter
                )]
            )
        case .delete:
            guard let preImage = operation.preImage else { return RestoreStatements(statements: []) }
            return try factory.restoreStatements(rows: [preImage], absentCells: [0: operation.absentColumnsBeforeWrite])
        case .insert:
            guard let postImage = operation.postImage else { return RestoreStatements(statements: []) }
            return try factory.lookedUpStatements(
                for: [RowChange(rowID: .existing(0), type: .delete, cellChanges: [], originalRow: postImage)],
                deletedRowIDs: [.existing(0)]
            )
        }
    }

    // MARK: - Keys

    // Where the save left the row, or for a delete where it was: an edit that rewrote the key moved it.
    private func savedImage(of operation: RowWriteOperation) -> [PluginCellValue]? {
        operation.postImage ?? operation.preImage
    }

    private func primaryKey(of operation: RowWriteOperation) -> RewindRowKey? {
        guard let source = savedImage(of: operation) else { return nil }
        return primaryKey(of: source, columns: operation.columns, keyColumns: operation.primaryKeyColumns)
    }

    private func keyBeforeMove(of operation: RowWriteOperation) -> RewindRowKey? {
        guard operation.kind == .update, let preImage = operation.preImage else { return nil }
        let before = primaryKey(of: preImage, columns: operation.columns, keyColumns: operation.primaryKeyColumns)
        return before == primaryKey(of: operation) ? nil : before
    }

    // A rewind that already ran put a moved row back under its old key, where it reads as restored.
    private func readImages(of operation: RowWriteOperation) -> [[PluginCellValue]] {
        guard let saved = savedImage(of: operation) else { return [] }
        guard keyBeforeMove(of: operation) != nil, let preImage = operation.preImage else { return [saved] }
        return [saved, preImage]
    }

    // Only a row holding the old values, so another row that took the old key since is not mistaken for this one.
    private func rowRestoredUnderKeyBefore(
        _ operation: RowWriteOperation,
        in current: [RewindRowKey: RewindCurrentRow]
    ) -> RewindCurrentRow? {
        guard let key = keyBeforeMove(of: operation), let row = current[key], let preImage = operation.preImage,
              matches(row, preImage, absent: operation.preImageAbsentColumns, on: operation)
        else { return nil }
        return row
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
            && operation.primaryKeyColumns.allSatisfy {
                keyValue(in: savedImage(of: operation), of: operation, column: $0) != nil
            }
    }

    private func keyValue(in image: [PluginCellValue]?, of operation: RowWriteOperation, column: String) -> String? {
        guard let image,
              let index = operation.columns.firstIndex(of: column),
              index < image.count
        else { return nil }
        return image[index].asText
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
    var locator: String?

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
        let locators = result.rowLocators?.count == result.rows.count ? result.rowLocators : nil
        guard matchingByName, result.columns != columns else {
            return result.rows.enumerated().map { index, values in
                RewindCurrentRow(
                    values: values, absentColumns: result.absentCells[index] ?? [], locator: locators?[index] ?? nil
                )
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
            return RewindCurrentRow(values: aligned, absentColumns: absent, locator: locators?[index] ?? nil)
        }
    }
}
