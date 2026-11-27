import Foundation
import os
import TableProPluginKit
import TableProSQLFile
import TableProSQLGrammar

internal enum ImportTransactionOutcome: Equatable, Sendable {
    case untracked
    case committed
    case rolledBack
    case committedBeforeRollback
    case endedByServer
    case endedByFile
}

final class ImportDataSinkAdapter: PluginImportDataSink, @unchecked Sendable {
    let databaseTypeId: String
    let targetTable: String?
    private let targetSchema: String?

    private let importControl: ImportSinkRun?
    private let driver: DatabaseDriver
    private let databaseType: DatabaseType
    private let rowGenerator: SQLStatementGenerator?
    private let typedRowGenerator = OSAllocatedUnfairLock<SQLStatementGenerator?>(uncheckedState: nil)
    private let targetValues = OSAllocatedUnfairLock<ImportTargetValues?>(initialState: nil)
    private let binaryText: ImportBinaryText?
    private let rowWriter: ImportRowWriter
    private let immutableColumns = OSAllocatedUnfairLock<Set<String>?>(initialState: nil)

    private let isCancelled: @Sendable () -> Bool

    private let tableEditDialect: TableEditDialect?
    private let nameHazards = OSAllocatedUnfairLock<[String]>(initialState: [])
    private let ownsTransaction = OSAllocatedUnfairLock(initialState: false)
    private let leavesTransactionOpen = OSAllocatedUnfairLock(initialState: false)
    private let disabledForeignKeys = OSAllocatedUnfairLock(initialState: false)
    private let joinsTransaction: Bool
    private let commitMode: ConnectionCommitMode
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
        binaryText: ImportBinaryText? = nil,
        joinsTransaction: Bool = false,
        commitMode: ConnectionCommitMode = .automatic,
        importRun: ImportRun? = nil,
        fileIndex: Int? = 0,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.importControl = importRun.map {
            ImportSinkRun(run: $0, driver: driver, databaseType: databaseType, fileIndex: fileIndex,
                          targetTable: targetTable, targetSchema: targetSchema, joinsTransaction: joinsTransaction,
                          commitMode: commitMode)
        }
        self.commitMode = commitMode
        self.isCancelled = isCancelled
        self.binaryText = binaryText
        self.rowWriter = ImportRowWriter(
            databaseTypeId: databaseType.rawValue,
            columnMapping: columnMapping,
            sourceFields: sourceFields,
            rowWriting: rowWriting
        )
        self.joinsTransaction = joinsTransaction
        self.driver = driver
        self.databaseType = databaseType
        self.tableEditDialect = TableEditDialect.of(databaseType)
        self.databaseTypeId = databaseType.rawValue
        self.targetTable = targetTable
        self.targetSchema = targetSchema
        if let targetTable, Self.canWriteRows(into: databaseType) {
            self.rowGenerator = Self.makeRowGenerator(
                table: targetTable, schema: targetSchema, databaseType: databaseType, driver: driver
            )
        } else {
            self.rowGenerator = nil
        }
    }

    // The driver's quoting, not the dialect's: ClickHouse reads a backslash escape inside backquotes.
    private static func makeRowGenerator(
        table: String,
        schema: String?,
        databaseType: DatabaseType,
        driver: DatabaseDriver,
        columnTypeNames: [String: String] = [:]
    ) -> SQLStatementGenerator? {
        try? SQLStatementGenerator(
            tableName: table,
            schemaName: schema,
            columns: [],
            primaryKeyColumns: [],
            databaseType: databaseType,
            columnTypeNames: columnTypeNames,
            quoteIdentifier: driver.quoteIdentifier,
            rowUpdateStatement: driver.rowUpdateStatement,
            rowDeleteStatement: driver.rowDeleteStatement
        )
    }

    // The driver gets each parameter's column type: Oracle stored `00123` bound to a VARCHAR2 as 123 without it, and
    // MySQL stores text bound to a BIT column as its bytes, so a 5 lands as 53.
    private func writingGenerator() async throws -> SQLStatementGenerator? {
        guard let rowGenerator, let targetTable else { return rowGenerator }
        if let typed = typedRowGenerator.withLockUnchecked({ $0 }) { return typed }
        let typed = Self.makeRowGenerator(
            table: targetTable, schema: targetSchema, databaseType: databaseType, driver: driver,
            columnTypeNames: try await targetColumnValues().typeNames
        ) ?? rowGenerator
        typedRowGenerator.withLockUnchecked { $0 = typed }
        return typed
    }

    // Read once per import, for the typed binding above and for what a file's text means in each column.
    private func targetColumnValues() async throws -> ImportTargetValues {
        if let known = targetValues.withLock({ $0 }) { return known }
        guard let targetTable else {
            throw PluginImportError.importFailed("No target table configured for row import")
        }
        // A BIT family and Oracle write wrong values without the types; elsewhere the import goes on as it did before
        // the types were read, and the error stays out of the run's list.
        let family = SQLTypeFamily.of(databaseType)
        let needsTypes = family.readsBitsAsDecimal || family == .oracle
        let read: [ColumnInfo]? = try await importedData {
            do {
                return try await self.driver.fetchColumns(table: targetTable, schema: self.targetSchema)
            } catch where !needsTypes && !(error is CancellationError) {
                Self.logger.warning(
                    "Import writes untyped values: the target's columns could not be read: \(error.localizedDescription, privacy: .private)"
                )
                return nil
            }
        }
        let values = ImportTargetValues(
            columns: (read ?? []).map {
                (name: $0.name, typeName: $0.typeNameForClassification, isGenerated: $0.isGenerated)
            },
            databaseType: databaseType,
            binaryText: binaryText
        )
        targetValues.withLock { $0 = values }
        return values
    }

    private func writingTarget() async throws -> ImportRowWriter.Target? {
        guard let targetTable, let generator = try await writingGenerator() else { return nil }
        return ImportRowWriter.Target(
            tableName: targetTable, statements: generator.importStatements, values: try await targetColumnValues()
        )
    }

    private var writerHost: ImportRowWriter.Host {
        ImportRowWriter.Host(
            execute: { statement, purpose in try await self.runWriterStatement(statement, purpose) },
            columnsUpdateCannotSet: { try await self.columnsUpdateCannotSet() },
            isCancelled: isCancelled
        )
    }

    private func runWriterStatement(
        _ statement: SQLImportStatement,
        _ purpose: ImportRowWriter.Purpose
    ) async throws -> [[String?]] {
        let parameterized = ParameterizedStatement(statement)
        let driver = self.driver
        func sendStatement() async throws -> QueryResult {
            try await driver.executeParameterized(
                query: parameterized.sql, parameters: parameterized.parameters, context: parameterized.context
            )
        }
        switch purpose {
        case .matchProbe:
            let result = try await importedData { try await sendStatement() }
            return result.rows.map { $0.map(\.asText) }
        case .write(let rows):
            _ = try await importedData(rows: rows, writes: true) { try await sendStatement() }
            return []
        }
    }

    func execute(statement: String) async throws {
        try await execute(statement: statement, line: 1)
    }

    var rowTally: ImportRowTally {
        rowWriter.tally
    }

    var transactionOutcome: ImportTransactionOutcome {
        if let importControl { return importControl.transactionOutcome }
        return transactionRecord.withLock { record in
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

    var nameHazardStatements: [String] {
        nameHazards.withLock { $0 }
    }

    // Read before the statement runs: one that fails part way can already have made a temporary table.
    private func noteNameHazards(in text: String, grammar: SQLLexicalGrammar) {
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
        // The file's own statements change how the session reads the next one.
        let grammar = SQLLexicalResolver.readings(for: databaseType, session: driver.sessionLexicalState).execution
        try await importedData(writes: true, statement: statement) {
            self.noteNameHazards(in: statement, grammar: grammar)
            try await self.send(statement, line: line, grammar: grammar)
            await self.noteTransactionEnd(after: statement, grammar: grammar)
        }
    }

    // A write or definition alone: no transaction boundary, no setting, one statement as this session splits it.
    func batches(_ statement: String) -> Bool {
        guard driver.supportsStatementBatches, Self.readsAlike(statement, session: driver.sessionLexicalState) else {
            return false
        }
        let grammar = SQLLexicalResolver.readings(for: databaseType, session: driver.sessionLexicalState).execution
        guard !grammar.contains(.batchSeparatorLines),
              Self.batchedKeywords.contains(QueryClassifier.leadingKeyword(of: statement, grammar: grammar)),
              !CatalogChangeClassifier.effect(of: statement, databaseType: databaseType, grammar: grammar).endsTransaction,
              statement.range(of: "set_config", options: .caseInsensitive) == nil
        else { return false }
        return SQLStatementScanner.executableStatements(in: statement, grammar: grammar).count == 1
    }

    // A read is left out because a call in one is how a dump changes a setting.
    private static let batchedKeywords: Set<String> = [
        "INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "DROP", "COMMENT", "GRANT", "REVOKE", "TRUNCATE",
    ]

    private static let backslashEscapes: SQLLexicalFeatures = [
        .backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes, .backslashEscapesInBackticks,
    ]

    // The file is split ahead of what runs, so a waiting statement must split the same under every reading the session
    // can switch to. The only switches a session reports are backslash escapes, and text without a backslash reads
    // alike under each.
    private static func readsAlike(_ statement: String, session: PluginSessionLexicalState?) -> Bool {
        guard let determined = session?.determined, !determined.isEmpty else { return true }
        return backslashEscapes.isSuperset(of: determined) && !statement.utf8.contains(UInt8(ascii: "\\"))
    }

    func execute(statements: [PluginImportStatement], readAhead: Bool) async throws {
        let readingRules = driver.sessionLexicalState
        try await run(statements)
        // The element the file was read for was split under the rules in force before these ran.
        guard !readAhead || driver.sessionLexicalState == readingRules else {
            throw PluginImportBatchFailure(index: statements.count, underlying: ImportReadingRulesChanged())
        }
    }

    private func run(_ statements: [PluginImportStatement]) async throws {
        let grammar = SQLLexicalResolver.readings(for: databaseType, session: driver.sessionLexicalState).execution
        let texts = statements.map(\.text)
        let driver = self.driver
        let send: () async throws -> [BatchedStatementOutcome]? = {
            try await driver.executeStatements(texts.map { BatchedStatement(sql: $0) })
        }
        let answered = if let importControl {
            try await importControl.statements(texts, operation: send)
        } else {
            try await send()
        }
        // Declined, as outside a transaction block: each goes alone, through its own admission.
        guard let outcomes = answered else {
            for (index, statement) in statements.enumerated() {
                do {
                    try await execute(statement: statement.text, line: statement.line)
                } catch {
                    throw PluginImportBatchFailure(index: index, underlying: error)
                }
            }
            return
        }
        for (index, (statement, outcome)) in zip(statements, outcomes).enumerated() {
            noteNameHazards(in: statement.text, grammar: grammar)
            if case .failed(let error) = outcome { throw PluginImportBatchFailure(index: index, underlying: error) }
            await noteTransactionEnd(after: statement.text, grammar: grammar)
        }
        guard outcomes.count >= statements.count else {
            throw PluginImportBatchFailure(
                index: outcomes.count,
                underlying: DatabaseError.queryFailed(String(localized: "The driver did not report every statement it was sent."))
            )
        }
    }

    // The driver's Stop ends a copy at once (a CopyFail, and a cancel request when the server takes no data).
    func copyFromStandardInput(statement: String, line: Int, rows: PluginCopyData) async throws {
        guard driver.supportsCopyFromStandardInput else { throw SQLFileParseError.copyFromStandardInput(line: line) }
        let driver = self.driver
        try await importedData(writes: true, statement: statement, interrupt: { try? driver.cancelQuery() }) {
            _ = try await driver.copyFromStandardInput(statement: statement, rows: rows, context: nil)
        }
    }

    // T-SQL scopes a variable and a TRY...CATCH to its batch, so a batch goes whole where the driver can send it so.
    private func send(_ statement: String, line: Int, grammar: SQLLexicalGrammar) async throws {
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

    private static let batchRowCap = 1

    func insertRow(_ values: [String: PluginCellValue]) async throws {
        guard let targetTable else {
            throw PluginImportError.importFailed("No target table configured for row import")
        }
        guard let target = try await writingTarget() else {
            throw PluginImportError.importFailed("Could not resolve SQL dialect for \(targetTable)")
        }
        try await rowWriter.insertRow(values, into: target, host: writerHost)
    }

    func insertRows(_ rows: [[String: PluginCellValue]]) async throws {
        guard targetTable != nil else {
            throw PluginImportError.importFailed("No target table configured for row import")
        }
        guard let target = try await writingTarget() else {
            throw PluginImportError.importFailed("Could not resolve SQL dialect for row import")
        }
        try await rowWriter.insertRows(rows, into: target, host: writerHost)
    }

    // Rows already in column order, written in the same budgeted batches as a mapped import.
    func insertRows(
        columns: [String],
        values rows: [[PluginCellValue]],
        onWrite: (Int) -> Void = { _ in }
    ) async throws {
        guard rowGenerator != nil else {
            throw PluginImportError.importFailed("No target table configured for row import")
        }
        guard !columns.isEmpty, !rows.isEmpty, let target = try await writingTarget() else { return }
        try await rowWriter.insertRows(columns: columns, values: rows, into: target, host: writerHost, onWrite: onWrite)
    }

    static func foldedKeyValue(_ value: PluginCellValue) -> String {
        ImportRowWriter.foldedKeyValue(value)
    }

    private func columnsUpdateCannotSet() async throws -> Set<String> {
        if let known = immutableColumns.withLock({ $0 }) { return known }
        guard let targetTable else { return [] }
        let fetched = try await importedData {
            try await self.driver.fetchImmutableColumns(table: targetTable, schema: self.targetSchema)
        }
        immutableColumns.withLock { $0 = fetched }
        return fetched
    }

    func mappedColumnsAndValues(_ values: [String: PluginCellValue]) -> ([String], [PluginCellValue]) {
        rowWriter.mappedColumnsAndValues(values)
    }

    func deleteAllRowsFromTargetTable() async throws {
        guard targetTable != nil, let rowGenerator else {
            throw PluginImportError.importFailed("No target table configured for row import")
        }
        let statement = try rowWriter.clearingStatement(using: rowGenerator.importStatements)
        try await importedData(writes: true, deletes: true) {
            _ = try await self.driver.execute(query: statement)
        }
    }

    func beginTransaction() async throws {
        if let importControl { return try await importControl.begin() }
        guard !joinsTransaction else { return }
        let state = await driver.heldSessionTransactionState()
        if commitMode == .manual {
            guard !disabledForeignKeys.withLock({ $0 }) else { throw ManualCommitForeignKeyRefusal() }
            try ManualCommit.refuseUnheldWrite(supportsTransactions: driver.supportsTransactions, sessionState: state)
        }
        let owner = WriteTransactionOwner.resolve(
            supportsTransactions: driver.supportsTransactions,
            sessionState: state,
            commitMode: commitMode
        )
        ownsTransaction.withLock { $0 = owner.sendsBegin }
        leavesTransactionOpen.withLock { $0 = owner.sendsBegin && !owner.commitsAtEnd }
        transactionRecord.withLock { $0 = TransactionRecord() }
        guard owner.sendsBegin else { return }
        try await driver.beginTransaction(mode: .readWrite)
        if owner == .held { ManualCommit.turnHold?.mark(true) }
    }

    func commitTransaction() async throws {
        if let importControl { return try await importControl.commit() }
        guard ownsTransaction.withLock({ $0 }) else { return }
        // Manual Commit: the imported rows stay pending in the transaction the user commits.
        guard !leavesTransactionOpen.withLock({ $0 }) else {
            ownsTransaction.withLock { $0 = false }
            return
        }
        try await driver.commitTransaction()
        ownsTransaction.withLock { $0 = false }
        transactionRecord.withLock { $0.ending = .committed }
    }

    func rollbackTransaction() async throws {
        if let importControl { return try await importControl.rollback() }
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

    // After a success only; the session state is asked only where DDL commits, since SQL Server answers with a query.
    private func noteTransactionEnd(after statement: String, grammar: SQLLexicalGrammar) async {
        guard ownsTransaction.withLock({ $0 }) else { return }
        switch fileTransactionEnd(of: statement, grammar: grammar) {
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

    private func fileTransactionEnd(of statement: String, grammar: SQLLexicalGrammar) -> FileTransactionEnd? {
        let effect = CatalogChangeClassifier.effect(of: statement, databaseType: databaseType, grammar: grammar)
        guard effect.endsTransaction else { return nil }
        let keyword = QueryClassifier.leadingKeyword(of: statement, grammar: grammar)
        return Self.rollbackKeywords.contains(keyword) ? .rollback : .commit
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
            try await withImportSession {
                _ = try await self.driver.execute(query: stmt)
            }
        }
        disabledForeignKeys.withLock { $0 = true }
        importControl?.noteForeignKeysDisabled()
    }

    func enableForeignKeyChecks() async throws {
        guard let statements = driver.foreignKeyEnableStatements() else { return }
        for stmt in statements {
            try await withImportSession {
                _ = try await self.driver.execute(query: stmt)
            }
        }
    }

    func recordImportError(_ error: any Error) async {
        guard let importControl else { return }
        try? await importControl.session { importControl.run.record { $0.recordError(error) } }
    }

    func prepareImportRun() async throws {
        if let importControl { return try await importControl.prepare() }
        guard commitMode == .manual else { return }
        let state = await driver.heldSessionTransactionState()
        try ManualCommit.refuseUnheldWrite(supportsTransactions: driver.supportsTransactions, sessionState: state)
    }

    func importCheckpoint() async throws {
        try await importControl?.checkpoint()
    }

    func withImportSession<T>(_ operation: () async throws -> T) async throws -> T {
        if let importControl { return try await importControl.session(operation) }
        return try await operation()
    }

    private func importedData<T>(
        rows: Int = 0,
        writes: Bool = false,
        deletes: Bool = false,
        statement: String? = nil,
        interrupt: (@Sendable () -> Void)? = nil,
        operation: () async throws -> T
    ) async throws -> T {
        if let importControl {
            return try await importControl.data(
                rows: rows, writes: writes, deletes: deletes, statement: statement, interrupt: interrupt,
                operation: operation
            )
        }
        return try await operation()
    }
}

internal struct ImportReadingRulesChanged: LocalizedError {
    var errorDescription: String? {
        String(localized: """
            Statements sent together changed how the database reads text after the import had read past them, so the \
            import stopped there. Import the file again with Wrap in transaction turned off.
            """)
    }
}
