import Foundation
import TableProPluginKit

// The write half of a row import: mapping, batching, matching and the mode decision. The host's sink owns the
// connection, the transaction, foreign keys, COPY and cancellation, and runs every statement through `Host.execute`.
nonisolated final class ImportRowWriter: @unchecked Sendable {
    nonisolated enum Purpose: Equatable, Sendable {
        case matchProbe
        case write(rows: Int)
    }

    // What one table takes, read once per import by the host.
    nonisolated struct Target {
        let tableName: String
        let statements: SQLImportStatements
        let values: ImportTargetValues
    }

    nonisolated struct Host {
        // A probe answers its rows as text; a write's answer is ignored.
        let execute: (_ statement: SQLImportStatement, _ purpose: Purpose) async throws -> [[String?]]
        let columnsUpdateCannotSet: () async throws -> Set<String>
        let isCancelled: () -> Bool
    }

    let rowWriting: ImportRowWriting
    private let databaseTypeId: String
    private let exactMapping: [String: String]
    private let foldedMapping: [String: String]
    private let sourceFields: Set<String>
    private let sourceFieldsPerFoldedName: [String: Int]
    private let tallyLock = NSLock()
    private var currentTally: ImportRowTally

    init(
        databaseTypeId: String,
        columnMapping: [String: String],
        sourceFields: Set<String>,
        rowWriting: ImportRowWriting
    ) {
        self.databaseTypeId = databaseTypeId
        self.rowWriting = rowWriting
        self.currentTally = ImportRowTally(mode: rowWriting.mode)
        self.exactMapping = columnMapping
        self.sourceFields = sourceFields
        self.sourceFieldsPerFoldedName = Dictionary(sourceFields.map { ($0.lowercased(), 1) }, uniquingKeysWith: +)
        self.foldedMapping = Dictionary(grouping: columnMapping, by: { $0.key.lowercased() })
            .compactMapValues { $0.count == 1 ? $0.first?.value : nil }
    }

    var tally: ImportRowTally {
        tallyLock.lock()
        defer { tallyLock.unlock() }
        return currentTally
    }

    private func recordTally(_ change: (inout ImportRowTally) -> Void) {
        tallyLock.lock()
        defer { tallyLock.unlock() }
        change(&currentTally)
    }

    // MARK: - Writing

    func insertRow(_ values: [String: PluginCellValue], into target: Target, host: Host) async throws {
        let row = try writableRows([values], target: target)[0]
        guard !rowWriting.mode.matchesExistingRows else {
            try await writeMatching([row], target: target, host: host)
            return
        }
        guard !row.columns.isEmpty else {
            try await insertDefaultRows(1, target: target, host: host)
            return
        }
        guard let statement = target.statements.insertStatement(columns: row.columns, values: row.values) else {
            throw PluginImportError.importFailed(
                String(format: String(localized: "Could not build an INSERT for %@"), target.tableName)
            )
        }
        _ = try await host.execute(statement, .write(rows: 1))
        recordTally { $0.inserted += 1 }
    }

    func insertRows(_ rows: [[String: PluginCellValue]], into target: Target, host: Host) async throws {
        let writable = try writableRows(rows, target: target)
        if rowWriting.mode.matchesExistingRows {
            try await writeMatching(writable, target: target, host: host)
        } else {
            try await insertGrouped(writable, target: target, host: host)
        }
    }

    // Rows already in column order, written in the same budgeted batches as a mapped import.
    func insertRows(
        columns: [String],
        values rows: [[PluginCellValue]],
        into target: Target,
        host: Host,
        onWrite: (Int) -> Void = { _ in }
    ) async throws {
        try await insertGroup(rows, columns: columns, target: target, host: host, onWrite: onWrite)
    }

    // Clearing first would leave no row to match.
    func clearingStatement(using statements: SQLImportStatements) throws -> String {
        guard !rowWriting.mode.matchesExistingRows else {
            throw PluginImportError.importFailed(Self.matchingRefusesClearingMessage)
        }
        return statements.deleteAllRowsStatement()
    }

    nonisolated private struct MappedRow {
        let columns: [String]
        let values: [PluginCellValue]
    }

    // A row with no field, such as JSON's `{}` for an all-NULL row, is a row of defaults; a row whose fields all missed
    // the mapping is an error.
    private func writableRows(_ rows: [[String: PluginCellValue]], target: Target) throws -> [MappedRow] {
        try rows.map { values in
            let (columns, mappedValues) = mappedColumnsAndValues(values)
            if columns.isEmpty, !values.isEmpty {
                throw PluginImportError.importFailed(Self.unmappedRowMessage)
            }
            return MappedRow(columns: columns, values: try target.values.values(mappedValues, columns: columns))
        }
    }

    private func insertGrouped(_ rows: [MappedRow], target: Target, host: Host) async throws {
        var index = 0
        while index < rows.count {
            let columns = rows[index].columns
            var groupValues: [[PluginCellValue]] = [rows[index].values]
            var next = index + 1
            while next < rows.count, rows[next].columns == columns {
                groupValues.append(rows[next].values)
                next += 1
            }
            index = next

            if columns.isEmpty {
                try await insertDefaultRows(groupValues.count, target: target, host: host)
            } else {
                try await insertGroup(groupValues, columns: columns, target: target, host: host)
            }
        }
    }

    private func insertDefaultRows(_ rowCount: Int, target: Target, host: Host) async throws {
        guard let statement = target.statements.allDefaultsInsertStatement(
            firstColumn: target.values.firstWritableColumn
        ) else {
            throw PluginImportError.importFailed(String(
                format: String(localized: "This row has no values, and %@ has no way to insert a row of only defaults."),
                databaseTypeId
            ))
        }
        for _ in 0..<rowCount {
            guard !host.isCancelled() else { throw PluginImportCancellationError() }
            _ = try await host.execute(statement, .write(rows: 1))
            recordTally { $0.inserted += 1 }
        }
    }

    private func insertGroup(
        _ groupValues: [[PluginCellValue]],
        columns: [String],
        target: Target,
        host: Host,
        onWrite: (Int) -> Void = { _ in }
    ) async throws {
        let budget = SQLWriteBatchBudget(columnCount: columns.count, statements: target.statements)
        var filler = SQLWriteBatchFiller<[PluginCellValue]>(budget: budget)
        for row in groupValues {
            guard let batch = filler.append(row, bytes: budget.byteCount(of: row)) else {
                continue
            }
            try await write(batch, columns: columns, target: target, host: host)
            onWrite(batch.count)
        }
        guard let batch = filler.take() else { return }
        try await write(batch, columns: columns, target: target, host: host)
        onWrite(batch.count)
    }

    private func write(_ batch: [[PluginCellValue]], columns: [String], target: Target, host: Host) async throws {
        guard !host.isCancelled() else { throw PluginImportCancellationError() }
        guard let statement = target.statements.insertStatement(columns: columns, rows: batch) else {
            throw PluginImportError.importFailed(
                String(localized: "Could not build an INSERT for the mapped columns")
            )
        }
        _ = try await host.execute(statement, .write(rows: batch.count))
        recordTally { $0.inserted += batch.count }
    }

    // MARK: - Matching existing rows

    nonisolated private struct KeyedRow {
        let row: MappedRow
        let key: [PluginCellValue]
    }

    // Not the engines' upsert forms: they refuse a NOT NULL column the file leaves out even when the row exists.
    private func writeMatching(_ rows: [MappedRow], target: Target, host: Host) async throws {
        var run: [KeyedRow] = []
        var keysInRun = Set<[String]>()
        for row in rows {
            let key = try keyValues(of: row)
            // A repeated key has to see the write of its first occurrence, so the run ends before it.
            let folded = key.contains(where: \.isNull) ? nil : key.map(Self.foldedKeyValue)
            if let folded, keysInRun.contains(folded) {
                try await writeMatchedRun(run, target: target, host: host)
                run.removeAll(keepingCapacity: true)
                keysInRun.removeAll(keepingCapacity: true)
            }
            if let folded { keysInRun.insert(folded) }
            run.append(KeyedRow(row: row, key: key))
        }
        try await writeMatchedRun(run, target: target, host: host)
    }

    // Folds more than a collation or a numeric comparison does: two keys the database takes as one must not share a run.
    static func foldedKeyValue(_ value: PluginCellValue) -> String {
        switch value {
        case .null:
            return "null"
        case .bytes(let data):
            return "bytes:" + data.base64EncodedString()
        case .text(let text):
            let folded = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            // A Double, not a Decimal: a REAL column holds 0.1 and 0.100000000000000001 as one value.
            guard folded.contains(where: { $0.isASCII && $0.isNumber }),
                  folded.allSatisfy({ numberCharacters.contains($0) }),
                  let number = Double(folded) else {
                return "text:" + folded
            }
            return "number:\(number == 0 ? 0 : number)"
        }
    }

    private static let numberCharacters = Set("0123456789+-.e")

    private func keyValues(of row: MappedRow) throws -> [PluginCellValue] {
        try rowWriting.keyColumns.map { column in
            guard let index = row.columns.firstIndex(of: column) else {
                throw PluginImportError.importFailed(String(
                    format: String(localized: "This row has no value for the key column %@, so it cannot be matched."),
                    column
                ))
            }
            return row.values[index]
        }
    }

    private func writeMatchedRun(_ run: [KeyedRow], target: Target, host: Host) async throws {
        guard !run.isEmpty else { return }
        let counts = try await matchCounts(of: run.map(\.key), target: target, host: host)
        if let ambiguous = zip(run, counts).first(where: { $0.1 > 1 }) {
            throw PluginImportError.importFailed(String(
                format: String(localized: "The key %1$@ matched %2$@ rows, so the row was not written."),
                keyDescription(ambiguous.0.key),
                ambiguous.1.formatted()
            ))
        }

        // Writes go out in file order, so a new parent row lands before an update that points at it.
        var inserts: [MappedRow] = []
        for (entry, matches) in zip(run, counts) {
            switch (matches, rowWriting.mode) {
            case (0, .update):
                recordTally { $0.unmatched += 1 }
            case (0, _):
                inserts.append(entry.row)
            case (_, .update), (_, .upsert):
                try await insertGrouped(inserts, target: target, host: host)
                inserts.removeAll(keepingCapacity: true)
                try await update(entry, target: target, host: host)
            default:
                recordTally { $0.existing += 1 }
            }
        }
        try await insertGrouped(inserts, target: target, host: host)
    }

    // A column the engine never lets an UPDATE assign keeps its value, and is written only for an inserted row.
    private func update(_ entry: KeyedRow, target: Target, host: Host) async throws {
        let kept = Set(rowWriting.keyColumns).union(try await host.columnsUpdateCannotSet())
        let assignments = zip(entry.row.columns, entry.row.values).filter { !kept.contains($0.0) }
        guard !assignments.isEmpty else {
            recordTally { $0.existing += 1 }
            return
        }
        guard !host.isCancelled() else { throw PluginImportCancellationError() }
        guard let statement = target.statements.keyedUpdateStatement(
            columns: assignments.map(\.0),
            values: assignments.map(\.1),
            keyColumns: rowWriting.keyColumns,
            keyValues: entry.key
        ) else {
            throw PluginImportError.importFailed(String(localized: "Could not build an UPDATE for the mapped columns"))
        }
        _ = try await host.execute(statement, .write(rows: 1))
        recordTally { $0.updated += 1 }
    }

    private static let keysPerProbe = 100

    private func matchCounts(of keys: [[PluginCellValue]], target: Target, host: Host) async throws -> [Int] {
        let keyWidth = max(1, rowWriting.keyColumns.count)
        let perStatement = max(1, min(Self.keysPerProbe, target.statements.maxBindParameters / keyWidth))
        var counts: [Int] = []
        counts.reserveCapacity(keys.count)
        var start = 0
        while start < keys.count {
            let chunk = Array(keys[start..<min(start + perStatement, keys.count)])
            guard !host.isCancelled() else { throw PluginImportCancellationError() }
            guard let statement = target.statements.keyMatchCountStatement(
                keyColumns: rowWriting.keyColumns, keys: chunk
            ) else {
                throw PluginImportError.importFailed(String(localized: "Could not build the query that matches rows"))
            }
            let rows = try await host.execute(statement, .matchProbe)
            counts += try Self.counts(in: rows, expected: chunk.count)
            start += chunk.count
        }
        return counts
    }

    private static func counts(in rows: [[String?]], expected: Int) throws -> [Int] {
        var counts = [Int?](repeating: nil, count: expected)
        for row in rows {
            guard row.count >= 2, let position = integer(row[0]), counts.indices.contains(position),
                  let count = integer(row[1]) else { continue }
            counts[position] = count
        }
        let read = counts.compactMap { $0 }
        guard read.count == expected else {
            throw PluginImportError.importFailed(String(localized: "Could not read which rows are already in the table"))
        }
        return read
    }

    private static func integer(_ value: String?) -> Int? {
        guard let text = value?.trimmingCharacters(in: .whitespaces) else { return nil }
        return Int(text) ?? Double(text).flatMap { $0.rounded() == $0 ? Int(exactly: $0) : nil }
    }

    private func keyDescription(_ key: [PluginCellValue]) -> String {
        zip(rowWriting.keyColumns, key)
            .map { "\($0.0) = \($0.1.isNull ? "NULL" : $0.1.sortKey)" }
            .joined(separator: ", ")
    }

    // MARK: - Mapping

    func mappedColumnsAndValues(_ values: [String: PluginCellValue]) -> ([String], [PluginCellValue]) {
        let plan = mappingPlan(for: values)
        return (plan.columns, plan.fields.map { values[$0] ?? .null })
    }

    // Which field fills which column, sorted by column. It depends only on the row's field names, which every row of
    // a file shares, so it is resolved once per layout instead of folding and sorting every row's names again.
    nonisolated private struct MappingPlan {
        let fieldNames: Set<String>
        let fields: [String]
        let columns: [String]
    }

    private let planLock = NSLock()
    private var lastPlan: MappingPlan?

    private func mappingPlan(for values: [String: PluginCellValue]) -> MappingPlan {
        planLock.lock()
        let cached = lastPlan
        planLock.unlock()
        if let cached, cached.fieldNames.count == values.count,
           values.keys.allSatisfy({ cached.fieldNames.contains($0) }) {
            return cached
        }
        let plan = resolvePlan(fieldNames: Set(values.keys))
        planLock.lock()
        lastPlan = plan
        planLock.unlock()
        return plan
    }

    private func resolvePlan(fieldNames: Set<String>) -> MappingPlan {
        var pairs: [(column: String, field: String)] = []
        var matchedNames = Set<String>()
        for field in fieldNames {
            guard let column = exactMapping[field] else { continue }
            pairs.append((column, field))
            matchedNames.insert(field.lowercased())
        }
        let unmatched = fieldNames.filter { exactMapping[$0] == nil && !sourceFields.contains($0) }
        for (folded, group) in Dictionary(grouping: unmatched, by: { $0.lowercased() }) {
            guard group.count == 1, let field = group.first, !matchedNames.contains(folded),
                  sourceFieldsPerFoldedName[folded, default: 0] <= 1,
                  let column = foldedMapping[folded] else { continue }
            pairs.append((column, field))
        }
        pairs.sort { $0.column < $1.column }
        return MappingPlan(fieldNames: fieldNames, fields: pairs.map(\.field), columns: pairs.map(\.column))
    }

    private static var matchingRefusesClearingMessage: String {
        String(localized: """
            Delete existing rows before import empties the table, so no row would match. Turn it off, or import as \
            Insert.
            """)
    }

    private static var unmappedRowMessage: String {
        String(localized: "No values in this row matched the column mapping")
    }
}
