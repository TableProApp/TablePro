//
//  ImportDataSinkAdapter.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit
import TableProSQLGrammar

/// What became of the transaction an import opened, as far as the import saw.
internal enum ImportTransactionOutcome: Equatable, Sendable {
    /// No transaction of the import's own, or one it did not see end: what ran stays as it ran.
    case untracked
    case committed
    case rolledBack
    /// A statement that succeeded left no transaction open, as a `CREATE` or the file's own `COMMIT` does on MySQL, so
    /// what ran up to then was not rolled back.
    case committedBeforeRollback
    /// The transaction had ended by the rollback with nothing before that naming how: a deadlock rolls it back, a
    /// failing `CREATE` commits it, and the session reads the same after either.
    case endedByServer
    /// The file ran its own `ROLLBACK`, so what stays depends on what the file ran after it.
    case endedByFile
}

final class ImportDataSinkAdapter: PluginImportDataSink, @unchecked Sendable {
    let databaseTypeId: String
    let targetTable: String?
    private let targetSchema: String?

    private let driver: DatabaseDriver
    private let databaseType: DatabaseType
    private let grammar: SQLLexicalGrammar
    private let exactMapping: [String: String]
    private let foldedMapping: [String: String]
    private let sourceFields: Set<String>
    private let sourceFieldsPerFoldedName: [String: Int]
    private let rowGenerator: SQLStatementGenerator?
    private let rowWriting: ImportRowWriting
    private let tally: OSAllocatedUnfairLock<ImportRowTally>
    private let immutableColumns = OSAllocatedUnfairLock<Set<String>?>(initialState: nil)

    /// Asked before every statement this sink sends, because one `insertRows` call is no longer one
    /// statement: a byte-heavy batch, or an Oracle target that takes one row per statement, splits
    /// it into many awaited writes. The callers check their own cancellation only before entering
    /// the sink, so without this a Stop was followed by every remaining INSERT of the batch.
    private let isCancelled: @Sendable () -> Bool

    private let tableEditDialect: TableEditDialect?
    private let nameHazards = OSAllocatedUnfairLock<[String]>(initialState: [])
    /// Whether this import opened the transaction it is in. A session connection can already hold
    /// the user's own: a `BEGIN` there would join it, and the import's `COMMIT` would commit work the
    /// user never asked to commit, so the import then runs inside it and leaves ending it to them.
    private let ownsTransaction = OSAllocatedUnfairLock(initialState: false)
    /// One file of several imported in one run. The run opened the transaction and ends it, so this sink sends no
    /// `BEGIN`, `COMMIT` or `ROLLBACK`: reading the session would not stop it, since `.unknown` permits a `BEGIN`
    /// and MySQL commits the open transaction on one.
    private let joinsTransaction: Bool
    private let transactionRecord = OSAllocatedUnfairLock(initialState: TransactionRecord())

    private struct TransactionRecord {
        enum Ending {
            case committed
            case rolledBack
            case endedByServer
        }

        var hasCommittedEarly = false
        var isEndedByFile = false
        var ending: Ending?
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "ImportDataSinkAdapter")

    /// Rows go in as SQL `INSERT`s, so an engine with no SQL dialect can take none of them.
    static func canWriteRows(into databaseType: DatabaseType) -> Bool {
        (try? SQLStatementGenerator(
            tableName: "t", columns: [], primaryKeyColumns: [], databaseType: databaseType
        )) != nil
    }

    init(
        driver: DatabaseDriver,
        databaseType: DatabaseType,
        targetTable: String? = nil,
        targetSchema: String? = nil,
        columnMapping: [String: String] = [:],
        sourceFields: Set<String> = [],
        rowWriting: ImportRowWriting = .insert,
        joinsTransaction: Bool = false,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.isCancelled = isCancelled
        self.rowWriting = rowWriting
        self.tally = OSAllocatedUnfairLock(initialState: ImportRowTally(mode: rowWriting.mode))
        self.joinsTransaction = joinsTransaction
        self.driver = driver
        self.databaseType = databaseType
        self.grammar = SQLLexicalResolver.readings(for: databaseType, session: driver.sessionLexicalState).execution
        self.tableEditDialect = TableEditDialect.of(databaseType)
        self.databaseTypeId = databaseType.rawValue
        self.targetTable = targetTable
        self.targetSchema = targetSchema
        self.exactMapping = columnMapping
        self.sourceFields = sourceFields
        self.sourceFieldsPerFoldedName = Dictionary(sourceFields.map { ($0.lowercased(), 1) }, uniquingKeysWith: +)
        self.foldedMapping = Dictionary(grouping: columnMapping, by: { $0.key.lowercased() })
            .compactMapValues { $0.count == 1 ? $0.first?.value : nil }
        // The driver's quoting, not the dialect's: ClickHouse reads a backslash escape inside backquotes.
        if let targetTable, Self.canWriteRows(into: databaseType) {
            self.rowGenerator = try? SQLStatementGenerator(
                tableName: targetTable,
                schemaName: targetSchema,
                columns: [],
                primaryKeyColumns: [],
                databaseType: databaseType,
                quoteIdentifier: driver.quoteIdentifier,
                rowUpdateStatement: driver.rowUpdateStatement,
                rowDeleteStatement: driver.rowDeleteStatement
            )
        } else {
            self.rowGenerator = nil
        }
    }

    func execute(statement: String) async throws {
        try await execute(statement: statement, line: 1)
    }

    var rowTally: ImportRowTally {
        tally.withLock { $0 }
    }

    var transactionOutcome: ImportTransactionOutcome {
        transactionRecord.withLock { record in
            switch record.ending {
            case .committed:
                return .committed
            case _ where record.hasCommittedEarly:
                return .committedBeforeRollback
            case _ where record.isEndedByFile:
                return .endedByFile
            case .rolledBack:
                return .rolledBack
            case .endedByServer:
                return .endedByServer
            case nil:
                return .untracked
            }
        }
    }

    /// What the file ran that changes where a name resolves for the rest of the session, such as a temporary table, so
    /// the catalog can stop following a later drop of that name onto the real table.
    var nameHazardStatements: [String] {
        nameHazards.withLock { $0 }
    }

    /// Read before the statement runs, because one that fails part way can already have made a temporary table.
    private func noteNameHazards(in text: String) {
        guard let tableEditDialect else { return }
        let statements = grammar.contains(.batchSeparatorLines)
            ? SQLStatementScanner.executableStatements(in: text, grammar: grammar).map(\.sql)
            : [text]
        let hazards = statements.filter {
            TableEditStatementParser.parse($0, dialect: tableEditDialect, grammar: grammar).changesNameHazards
        }
        guard !hazards.isEmpty else { return }
        nameHazards.withLock { $0 += hazards }
    }

    func execute(statement: String, line: Int) async throws {
        noteNameHazards(in: statement)
        try await send(statement, line: line)
        await noteTransactionEnd(after: statement)
    }

    /// A SQL Server file arrives a batch at a time, as sqlcmd reads it, or a statement at a time when it holds no `GO`
    /// line, and each goes to the server whole: T-SQL scopes a variable, a table variable and a `TRY...CATCH` to one
    /// batch, and a routine's body runs to the end of its batch. A driver that cannot send a batch whole runs its
    /// statements one by one, as the editor does.
    private func send(_ statement: String, line: Int) async throws {
        guard grammar.contains(.batchSeparatorLines) else {
            _ = try await driver.execute(query: statement)
            return
        }
        if driver.supportsResultSetBatches,
           let answer = try await driver.executeBatch(query: statement, rowCap: Self.batchRowCap, parameters: nil) {
            guard let failure = BatchErrorText.describe(answer.errors, batchStartLine: line) else { return }
            throw DatabaseError.queryFailed(failure)
        }
        for batchStatement in SQLStatementScanner.executableStatements(in: statement, grammar: grammar) {
            guard !isCancelled() else { throw PluginImportCancellationError() }
            _ = try await driver.execute(query: batchStatement.sql)
        }
    }

    /// An import shows no rows, so a batch keeps as few of each result set as a driver takes, and the rest are read
    /// past rather than held.
    private static let batchRowCap = 1

    func insertRow(_ values: [String: PluginCellValue]) async throws {
        guard let targetTable else {
            throw PluginImportError.importFailed("No target table configured for row import")
        }
        guard let rowGenerator else {
            throw PluginImportError.importFailed("Could not resolve SQL dialect for \(targetTable)")
        }

        let row = mappedRow(values)
        guard !row.columns.isEmpty else {
            guard values.isEmpty else {
                throw PluginImportError.importFailed(Self.unmappedRowMessage)
            }
            return
        }
        guard !rowWriting.mode.matchesExistingRows else {
            try await writeMatching([row], generator: rowGenerator)
            return
        }
        guard let statement = rowGenerator.insertStatement(columns: row.columns, values: row.values) else {
            throw PluginImportError.importFailed(
                String(format: String(localized: "Could not build an INSERT for %@"), targetTable)
            )
        }

        _ = try await driver.executeParameterized(query: statement.sql, parameters: statement.parameters)
        tally.withLock { $0.inserted += 1 }
    }

    func insertRows(_ rows: [[String: PluginCellValue]]) async throws {
        guard targetTable != nil else {
            throw PluginImportError.importFailed("No target table configured for row import")
        }
        guard let rowGenerator else {
            throw PluginImportError.importFailed("Could not resolve SQL dialect for row import")
        }

        let mapped = rows.map(mappedRow)
        if zip(rows, mapped).contains(where: { !$0.0.isEmpty && $0.1.columns.isEmpty }) {
            throw PluginImportError.importFailed(Self.unmappedRowMessage)
        }
        let writable = mapped.filter { !$0.columns.isEmpty }

        if rowWriting.mode.matchesExistingRows {
            try await writeMatching(writable, generator: rowGenerator)
        } else {
            try await insertGrouped(writable, generator: rowGenerator)
        }
    }

    private struct MappedRow {
        let columns: [String]
        let values: [PluginCellValue]
    }

    private func mappedRow(_ values: [String: PluginCellValue]) -> MappedRow {
        let (columns, mappedValues) = mappedColumnsAndValues(values)
        return MappedRow(columns: columns, values: mappedValues)
    }

    private func insertGrouped(_ rows: [MappedRow], generator: SQLStatementGenerator) async throws {
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

            try await insertGroup(groupValues, columns: columns, generator: generator)
        }
    }

    // Rows already in column order, written in the same budgeted batches as a mapped import.
    func insertRows(
        columns: [String],
        values rows: [[PluginCellValue]],
        onWrite: (Int) -> Void = { _ in }
    ) async throws {
        guard let rowGenerator else {
            throw PluginImportError.importFailed("No target table configured for row import")
        }
        guard !columns.isEmpty, !rows.isEmpty else { return }
        try await insertGroup(rows, columns: columns, generator: rowGenerator, onWrite: onWrite)
    }

    /// One budget per group, because a group is exactly the run of rows sharing one column set and
    /// the column set is what fixes a row's width. Bounded in bytes as well as parameters: 500 rows
    /// of three 1 MB values fit a three-column table's 21,845-row parameter ceiling and went out as
    /// a single 500 MB statement the server refused, failing the first batch and leaving nothing
    /// imported. The row cap also carries the engine's multi-row `VALUES` ceiling, which this path
    /// never consulted, so an Oracle target no longer gets a statement it cannot parse.
    private func insertGroup(
        _ groupValues: [[PluginCellValue]],
        columns: [String],
        generator: SQLStatementGenerator,
        onWrite: (Int) -> Void = { _ in }
    ) async throws {
        let budget = SQLWriteBatchBudget(columnCount: columns.count, generator: generator)
        var filler = SQLWriteBatchFiller<[PluginCellValue]>(budget: budget)
        for row in groupValues {
            guard let batch = filler.append(row, bytes: budget.byteCount(of: row)) else {
                continue
            }
            try await write(batch, columns: columns, generator: generator)
            onWrite(batch.count)
        }
        guard let batch = filler.take() else { return }
        try await write(batch, columns: columns, generator: generator)
        onWrite(batch.count)
    }

    private func write(
        _ batch: [[PluginCellValue]],
        columns: [String],
        generator: SQLStatementGenerator
    ) async throws {
        guard !isCancelled() else { throw PluginImportCancellationError() }
        guard let statement = generator.insertStatement(columns: columns, rows: batch) else {
            throw PluginImportError.importFailed(
                String(localized: "Could not build an INSERT for the mapped columns")
            )
        }
        _ = try await driver.executeParameterized(query: statement.sql, parameters: statement.parameters)
        tally.withLock { $0.inserted += batch.count }
    }

    // MARK: - Matching existing rows

    private struct KeyedRow {
        let row: MappedRow
        let key: [PluginCellValue]
    }

    // Not the engines' upsert forms: they refuse a NOT NULL column the file leaves out even when the row exists.
    private func writeMatching(_ rows: [MappedRow], generator: SQLStatementGenerator) async throws {
        var run: [KeyedRow] = []
        var keysInRun = Set<[String]>()
        for row in rows {
            let key = try keyValues(of: row)
            // A repeated key has to see the write of its first occurrence, so the run ends before it.
            let folded = key.contains(where: \.isNull) ? nil : key.map(Self.foldedKeyValue)
            if let folded, keysInRun.contains(folded) {
                try await writeMatchedRun(run, generator: generator)
                run.removeAll(keepingCapacity: true)
                keysInRun.removeAll(keepingCapacity: true)
            }
            if let folded { keysInRun.insert(folded) }
            run.append(KeyedRow(row: row, key: key))
        }
        try await writeMatchedRun(run, generator: generator)
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

    private func writeMatchedRun(_ run: [KeyedRow], generator: SQLStatementGenerator) async throws {
        guard !run.isEmpty else { return }
        let counts = try await matchCounts(of: run.map(\.key), generator: generator)
        if let ambiguous = zip(run, counts).first(where: { $0.1 > 1 }) {
            throw PluginImportError.importFailed(String(
                format: String(localized: "The key %1$@ matched %2$@ rows, so the row was not written."),
                keyDescription(ambiguous.0.key),
                ambiguous.1.formatted()
            ))
        }

        // Writes go out in file order, so a new parent row lands before an update that points at it.
        var inserts: [MappedRow] = []
        for (entry, count) in zip(run, counts) {
            switch (count, rowWriting.mode) {
            case (0, .update):
                tally.withLock { $0.unmatched += 1 }
            case (0, _):
                inserts.append(entry.row)
            case (_, .update), (_, .upsert):
                try await insertGrouped(inserts, generator: generator)
                inserts.removeAll(keepingCapacity: true)
                try await update(entry, generator: generator)
            default:
                tally.withLock { $0.existing += 1 }
            }
        }
        try await insertGrouped(inserts, generator: generator)
    }

    // A column the engine never lets an UPDATE assign keeps its value, and is written only for an inserted row.
    private func update(_ entry: KeyedRow, generator: SQLStatementGenerator) async throws {
        let kept = Set(rowWriting.keyColumns).union(try await columnsUpdateCannotSet())
        let assignments = zip(entry.row.columns, entry.row.values).filter { !kept.contains($0.0) }
        guard !assignments.isEmpty else {
            tally.withLock { $0.existing += 1 }
            return
        }
        guard !isCancelled() else { throw PluginImportCancellationError() }
        guard let statement = generator.keyedUpdateStatement(
            columns: assignments.map(\.0),
            values: assignments.map(\.1),
            keyColumns: rowWriting.keyColumns,
            keyValues: entry.key
        ) else {
            throw PluginImportError.importFailed(String(localized: "Could not build an UPDATE for the mapped columns"))
        }
        _ = try await driver.executeParameterized(query: statement.sql, parameters: statement.parameters)
        tally.withLock { $0.updated += 1 }
    }

    private func columnsUpdateCannotSet() async throws -> Set<String> {
        if let known = immutableColumns.withLock({ $0 }) { return known }
        guard let targetTable else { return [] }
        let fetched = try await driver.fetchImmutableColumns(table: targetTable, schema: targetSchema)
        immutableColumns.withLock { $0 = fetched }
        return fetched
    }

    private static let keysPerProbe = 100

    private func matchCounts(of keys: [[PluginCellValue]], generator: SQLStatementGenerator) async throws -> [Int] {
        let keyWidth = max(1, rowWriting.keyColumns.count)
        let perStatement = max(1, min(Self.keysPerProbe, generator.maxBindParameters / keyWidth))
        var counts: [Int] = []
        counts.reserveCapacity(keys.count)
        var start = 0
        while start < keys.count {
            let chunk = Array(keys[start..<min(start + perStatement, keys.count)])
            guard !isCancelled() else { throw PluginImportCancellationError() }
            guard let statement = generator.keyMatchCountStatement(keyColumns: rowWriting.keyColumns, keys: chunk) else {
                throw PluginImportError.importFailed(String(localized: "Could not build the query that matches rows"))
            }
            let result = try await driver.executeParameterized(query: statement.sql, parameters: statement.parameters)
            counts += try Self.counts(in: result, expected: chunk.count)
            start += chunk.count
        }
        return counts
    }

    private static func counts(in result: QueryResult, expected: Int) throws -> [Int] {
        var counts = [Int?](repeating: nil, count: expected)
        for row in result.rows {
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

    private static func integer(_ value: PluginCellValue) -> Int? {
        guard let text = value.asText?.trimmingCharacters(in: .whitespaces) else { return nil }
        return Int(text) ?? Double(text).flatMap { $0.rounded() == $0 ? Int(exactly: $0) : nil }
    }

    private func keyDescription(_ key: [PluginCellValue]) -> String {
        zip(rowWriting.keyColumns, key)
            .map { "\($0.0) = \($0.1.isNull ? "NULL" : $0.1.sortKey)" }
            .joined(separator: ", ")
    }

    private static var matchingRefusesClearingMessage: String {
        String(localized: """
            Delete existing rows before import empties the table, so no row would match. Turn it off, or import as \
            Insert.
            """)
    }

    /// A row carrying values none of which reach a mapped column writes nothing. Reporting it as
    /// inserted is how "Import completed" came to overstate what reached the database, so it is
    /// refused instead: skip-and-continue records it against its line, and the stop modes halt,
    /// because a mapping that matches no field of a row holding data is one the user needs to look
    /// at. A row with no values at all carries nothing to lose and passes through untouched.
    private static var unmappedRowMessage: String {
        String(localized: "No values in this row matched the column mapping")
    }

    /// Exact names first. A case-insensitive match is only a fallback for a field the sheet never
    /// listed, such as a JSON key respelled past the sample, and only when that spelling points at
    /// one listed field, one mapping key and one field of the row, none of them already matched.
    func mappedColumnsAndValues(_ values: [String: PluginCellValue]) -> ([String], [PluginCellValue]) {
        var pairs: [(column: String, value: PluginCellValue)] = []
        var matchedNames = Set<String>()
        for (field, value) in values {
            guard let column = exactMapping[field] else { continue }
            pairs.append((column, value))
            matchedNames.insert(field.lowercased())
        }
        let unmatched = values.filter { exactMapping[$0.key] == nil && !sourceFields.contains($0.key) }
        for (folded, group) in Dictionary(grouping: unmatched, by: { $0.key.lowercased() }) {
            guard group.count == 1, let entry = group.first, !matchedNames.contains(folded),
                  sourceFieldsPerFoldedName[folded, default: 0] <= 1,
                  let column = foldedMapping[folded] else { continue }
            pairs.append((column, entry.value))
        }
        pairs.sort { $0.column < $1.column }
        return (pairs.map(\.column), pairs.map(\.value))
    }

    func deleteAllRowsFromTargetTable() async throws {
        guard targetTable != nil, let rowGenerator else {
            throw PluginImportError.importFailed("No target table configured for row import")
        }
        guard !rowWriting.mode.matchesExistingRows else {
            throw PluginImportError.importFailed(Self.matchingRefusesClearingMessage)
        }
        _ = try await driver.execute(query: rowGenerator.deleteAllRowsStatement())
    }

    func beginTransaction() async throws {
        guard !joinsTransaction else { return }
        let owner = WriteTransactionOwner.resolve(
            supportsTransactions: driver.supportsTransactions,
            sessionState: await driver.heldSessionTransactionState()
        )
        ownsTransaction.withLock { $0 = owner.opensTransaction }
        transactionRecord.withLock { $0 = TransactionRecord() }
        guard owner.opensTransaction else { return }
        try await driver.beginTransaction(mode: .readWrite)
    }

    func commitTransaction() async throws {
        guard ownsTransaction.withLock({ $0 }) else { return }
        try await driver.commitTransaction()
        ownsTransaction.withLock { $0 = false }
        transactionRecord.withLock { $0.ending = .committed }
    }

    func rollbackTransaction() async throws {
        guard ownsTransaction.withLock({ $0 }) else { return }
        guard await !sessionHoldsNoTransaction() else {
            ownsTransaction.withLock { $0 = false }
            transactionRecord.withLock { $0.ending = .endedByServer }
            Self.logger.info("Import transaction was already ended by the server; no rollback sent")
            return
        }
        try await driver.rollbackTransaction()
        ownsTransaction.withLock { $0 = false }
        transactionRecord.withLock { $0.ending = .rolledBack }
    }

    /// Only a statement that succeeded can show a commit: a failure that ends the transaction may have rolled it back.
    /// The file's own `COMMIT` or `ROLLBACK` is read from its text on every engine, since the session reads the same
    /// after either. The state is read after each other statement, because under `autocommit = 0` the statement
    /// after a DDL opens a new transaction, and only where DDL commits: SQL Server reads its state with a query, which
    /// per statement would double the round trips.
    private func noteTransactionEnd(after statement: String) async {
        guard ownsTransaction.withLock({ $0 }) else { return }
        switch fileTransactionEnd(of: statement) {
        case .commit:
            transactionRecord.withLock { $0.hasCommittedEarly = true }
        case .rollback:
            transactionRecord.withLock { $0.isEndedByFile = true }
        case nil:
            guard !driver.supportsTransactionalDDL, await sessionHoldsNoTransaction() else { return }
            transactionRecord.withLock { $0.hasCommittedEarly = true }
        }
    }

    private enum FileTransactionEnd {
        case commit
        case rollback
    }

    /// `ROLLBACK TO SAVEPOINT` keeps the transaction, and the classifier already reads it as not ending one.
    private func fileTransactionEnd(of statement: String) -> FileTransactionEnd? {
        let effect = CatalogChangeClassifier.effect(of: statement, databaseType: databaseType, grammar: grammar)
        guard effect.endsTransaction else { return nil }
        return Self.rollbackKeywords.contains(QueryClassifier.leadingKeyword(of: statement)) ? .rollback : .commit
    }

    private static let rollbackKeywords: Set<String> = ["ROLLBACK", "ABORT"]

    private func sessionHoldsNoTransaction() async -> Bool {
        switch await driver.heldSessionTransactionState() {
        case .idle, .holdsSessionLocks:
            return true
        case .inTransaction, .abortedTransaction, .unknown:
            return false
        @unknown default:
            return false
        }
    }

    func disableForeignKeyChecks() async throws {
        guard let statements = driver.foreignKeyDisableStatements() else { return }
        for stmt in statements {
            _ = try await driver.execute(query: stmt)
        }
    }

    func enableForeignKeyChecks() async throws {
        guard let statements = driver.foreignKeyEnableStatements() else { return }
        for stmt in statements {
            _ = try await driver.execute(query: stmt)
        }
    }
}
