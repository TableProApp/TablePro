import Foundation
import os
import TableProDatabase
import TableProLogRedaction
import TableProModels
import TableProPluginKit
import TableProQuery
import TableProSQLFile
import TableProSQLGrammar

nonisolated enum ImportStopChoice: Sendable, Equatable {
    case rollBack
    case commit
}

// How the import's transaction ended, read from what the sink sent and what the session said after.
nonisolated enum ImportTransactionEnding: Sendable, Equatable {
    case committed
    case rolledBack
    // A COMMIT or a DDL statement in the file ended the transaction early, so a rollback after it kept those rows.
    case partlyCommitted
    // The import joined the user's open transaction, which holds the rows until the user commits or rolls back.
    case leftInOpenTransaction
    // The rows were written outside any transaction, each kept as it landed.
    case none
    // The server had already ended the transaction, so no ROLLBACK was sent.
    case endedByServer
}

// The iOS `PluginImportDataSink`. The shared `ImportRowWriter` builds every row statement; the sink owns the
// connection, the transaction, foreign key checks, COPY and the stop. A transaction is opened only when the session is
// idle and is then the import's own; one already open is joined and never committed or rolled back here (critic M8).
nonisolated final class MobileImportDataSink: PluginImportDataSink, @unchecked Sendable {
    nonisolated struct RowTarget: Sendable {
        let table: String
        let schema: String?
        let columnMapping: [String: String]
        let sourceFields: Set<String>
        let rowWriting: ImportRowWriting
        let binaryText: ImportBinaryText?
        // The database the import was started in, which a read names wherever the session has moved since.
        var database: String?
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "MobileImportDataSink")
    private static let ddlKeywords: Set<String> = ["CREATE", "ALTER", "DROP", "TRUNCATE", "RENAME", "GRANT", "REVOKE"]

    let databaseTypeId: String
    let targetTable: String?

    private let driver: any DatabaseDriver
    private let databaseType: DatabaseType
    private let rowTarget: RowTarget?
    private let dialect: (any MobileWriteDialect)?
    private let rowWriter: ImportRowWriter?
    private let externallyCancelled: @Sendable () -> Bool
    // A table an earlier import made, reused by a retry: emptied inside the import's transaction, so a retry that fails
    // or stops gives back the rows the first run kept (macOS `RowImportTableMaker`).
    private let clearsTargetFirst: Bool
    private let catalogGrammar: SQLLexicalGrammar
    private let catalogHold: ImportCatalogHold?

    private let lock = NSLock()
    private var stopChoice: ImportStopChoice?
    private var ownsTransaction = false
    private var joinedTransaction = false
    private var ending: ImportTransactionEnding?
    // Read statement by statement: a COMMIT, ROLLBACK or DDL statement in the file that ended the import's own
    // transaction, and rows that stay whatever the import's end does, committed by the file or written after that end.
    private var fileEndedTransaction = false
    private var fileRolledBack = false
    private var keptWrites = false
    private var disabledForeignKeys = false
    private var restoresForeignKeysAtFinish = false
    private var writerTarget: ImportRowWriter.Target?
    private var immutableColumns: Set<String>?
    private var clearedTarget = false
    private var recordedEffect = SessionLocalStatements.Effect()
    private var transactionEnded = false

    init(
        driver: any DatabaseDriver,
        databaseType: DatabaseType,
        rowTarget: RowTarget? = nil,
        dialect: (any MobileWriteDialect)? = nil,
        clearsTargetFirst: Bool = false,
        catalogHold: ImportCatalogHold? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.driver = driver
        self.catalogHold = catalogHold
        self.clearsTargetFirst = clearsTargetFirst
        self.catalogGrammar = SQLLexicalReadings.resolve(
            databaseTypeId: databaseType.rawValue, declared: nil, session: nil
        ).execution
        self.databaseType = databaseType
        self.databaseTypeId = databaseType.rawValue
        self.rowTarget = rowTarget
        self.targetTable = rowTarget?.table
        self.dialect = dialect
        self.externallyCancelled = isCancelled
        self.rowWriter = rowTarget.map {
            ImportRowWriter(
                databaseTypeId: databaseType.rawValue,
                columnMapping: $0.columnMapping,
                sourceFields: $0.sourceFields,
                rowWriting: $0.rowWriting
            )
        }
    }

    // MARK: - Stop

    // Latched. A rollback stop refuses every write and the commit; a commit stop refuses writes and skips the rollback the
    // plugin sends on its way out, so the run's `finish` commits what was written (macOS `ImportRun` admission).
    func stop(_ choice: ImportStopChoice) {
        lock.withLock {
            guard stopChoice == nil else { return }
            stopChoice = choice
        }
    }

    var requestedStop: ImportStopChoice? {
        lock.withLock { stopChoice }
    }

    private var isStopped: Bool {
        requestedStop != nil || externallyCancelled() || Task.isCancelled
    }

    private func admitWrite() throws {
        if isStopped { throw PluginImportCancellationError() }
    }

    var holdsOwnTransaction: Bool {
        lock.withLock { ownsTransaction }
    }

    var joinsUserTransaction: Bool {
        lock.withLock { joinedTransaction }
    }

    var rowTally: ImportRowTally? {
        rowWriter?.tally
    }

    // What the file's statements left on the session, read from each one before it is sent, so a statement that
    // failed counts too, as the query editor counts every statement a run planned.
    var sessionEffect: SessionLocalStatements.Effect {
        lock.withLock { recordedEffect }
    }

    // A transaction ended, the file's own or the import's, which takes back a `SET` made inside it.
    var endedTransaction: Bool {
        lock.withLock { transactionEnded }
    }

    // What the import left, once it is over. Asks the session when the sink opened nothing, so rows written into a
    // transaction the user holds are never reported as kept.
    func transactionEnding() async -> ImportTransactionEnding {
        let recorded = lock.withLock { () -> ImportTransactionEnding? in
            if keptWrites, ending == .rolledBack { return .partlyCommitted }
            if joinedTransaction {
                // The file's own COMMIT, ROLLBACK or implicitly committing DDL ended the user's transaction too.
                guard fileEndedTransaction else { return .leftInOpenTransaction }
                guard fileRolledBack else { return .committed }
                return keptWrites ? .partlyCommitted : .rolledBack
            }
            return ending
        }
        if let recorded { return recorded }
        switch await driver.sessionTransactionState() {
        case .explicitTransaction, .implicitTransaction, .abortedTransaction:
            return .leftInOpenTransaction
        case .idle, .unknown:
            return .none
        }
    }

    // Ends a transaction the sink still owns after the plugin returned: committed when the import finished or the user
    // chose to keep the rows, rolled back otherwise.
    func finish(commit: Bool) async {
        if holdsOwnTransaction {
            do {
                if commit {
                    try await commitOwned()
                } else {
                    try await rollbackOwned()
                }
            } catch {
                Self.logger.warning(
                    "Ending the import's transaction failed: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)"
                )
            }
        }
        guard lock.withLock({ restoresForeignKeysAtFinish }) else { return }
        do {
            try await restoreForeignKeyChecks()
        } catch {
            Self.logger.warning(
                "Turning foreign key checks back on failed: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    // MARK: - Transactions

    // A reused table is emptied right after, in the transaction the sink opened or joined.
    func beginTransaction() async throws {
        try await openOrJoinTransaction()
        try await clearTargetIfDue()
    }

    private func openOrJoinTransaction() async throws {
        try admitWrite()
        guard driver.supportsTransactions else { return }
        let state = await driver.sessionTransactionState()
        guard WriteTransactionPolicy.opensTransaction(supportsTransactions: true, state: state, statementCount: 2) else {
            lock.withLock {
                joinedTransaction = state != .idle
                ending = nil
            }
            return
        }
        try await driver.beginTransaction(mode: .readWrite)
        lock.withLock {
            ownsTransaction = true
            fileEndedTransaction = false
            keptWrites = false
            ending = nil
        }
    }

    func commitTransaction() async throws {
        switch requestedStop {
        case .rollBack?:
            throw PluginImportCancellationError()
        case .commit?, nil:
            try await commitOwned()
        }
    }

    func rollbackTransaction() async throws {
        guard requestedStop != .commit else { return }
        try await rollbackOwned()
    }

    // A COMMIT in an aborted PostgreSQL transaction ends it as a rollback with no error, so it is not reported as kept.
    private func commitOwned() async throws {
        guard holdsOwnTransaction else { return }
        switch await driver.sessionTransactionState() {
        case .abortedTransaction:
            try await rollbackOwned()
            return
        // The file's own COMMIT or ROLLBACK, or a DDL statement, already ended it; a COMMIT now would fail on SQLite.
        case .idle:
            lock.withLock {
                ownsTransaction = false
                transactionEnded = true
                ending = keptWrites ? .committed : endedBeforeTheImportLocked
            }
            return
        case .explicitTransaction, .implicitTransaction, .unknown:
            break
        }
        try await driver.commitTransaction()
        lock.withLock {
            ownsTransaction = false
            transactionEnded = true
            ending = .committed
        }
    }

    private func rollbackOwned() async throws {
        guard holdsOwnTransaction else { return }
        switch await driver.sessionTransactionState() {
        case .idle:
            lock.withLock {
                ownsTransaction = false
                transactionEnded = true
                ending = keptWrites ? .rolledBack : endedBeforeTheImportLocked
            }
            Self.logger.info("The import's transaction had already ended; no rollback sent")
            return
        case .explicitTransaction, .implicitTransaction, .abortedTransaction, .unknown:
            break
        }
        try await driver.rollbackTransaction()
        lock.withLock {
            ownsTransaction = false
            transactionEnded = true
            ending = .rolledBack
        }
    }

    // MARK: - Foreign keys

    func disableForeignKeyChecks() async throws {
        let statements = driver.foreignKeyCheckStatements(enabled: false)
        for statement in statements {
            _ = try await driver.execute(query: statement)
        }
        lock.withLock { disabledForeignKeys = !statements.isEmpty }
    }

    // SQLite ignores the re-enable inside a transaction and a rollback takes PostgreSQL's back, so while the sink still
    // owns one, as after Stop and Commit, `finish` turns the checks back on once it has ended it.
    func enableForeignKeyChecks() async throws {
        let restoresNow = lock.withLock { () -> Bool in
            guard disabledForeignKeys else { return false }
            guard !ownsTransaction else {
                restoresForeignKeysAtFinish = true
                return false
            }
            return true
        }
        guard restoresNow else { return }
        try await restoreForeignKeyChecks()
    }

    private func restoreForeignKeyChecks() async throws {
        for statement in driver.foreignKeyCheckStatements(enabled: true) {
            _ = try await driver.execute(query: statement)
        }
        lock.withLock {
            disabledForeignKeys = false
            restoresForeignKeysAtFinish = false
        }
    }

    // MARK: - Statements

    func execute(statement: String) async throws {
        try await execute(statement: statement, line: 1)
    }

    func execute(statement: String, line: Int) async throws {
        try admitWrite()
        noteSessionEffect(of: statement)
        if let catalogHold, SessionLocalStatements.changesDatabases(statement, databaseType: databaseType) {
            await catalogHold.holdOnce()
        }
        let grammar = SQLImportFile.grammar(for: databaseType, session: driver.settledLexicalFacts)
        // MySQL commits the open transaction before a DDL statement runs, so one that then fails still ended it.
        do {
            if grammar.contains(.batchSeparatorLines), !driver.sendsBatchesWhole {
                for piece in SQLStatementScanner.executableStatements(in: statement, grammar: grammar) {
                    try admitWrite()
                    _ = try await driver.execute(query: piece.sql)
                }
            } else {
                _ = try await driver.execute(query: statement)
            }
        } catch {
            await noteEffects(of: statement)
            throw error
        }
        await noteEffects(of: statement)
    }

    private func noteSessionEffect(of statement: String) {
        let effect = SessionLocalStatements.effect(of: [statement], databaseType: databaseType)
        let ends = SQLCatalogEffectClassifier.effect(of: statement, grammar: catalogGrammar).endsTransaction
        lock.withLock {
            recordedEffect.temporaryTables.formUnion(effect.temporaryTables)
            recordedEffect.leavesCatalog = recordedEffect.leavesCatalog || effect.leavesCatalog
            recordedEffect.usesDatabase = recordedEffect.usesDatabase || effect.usesDatabase
            if ends { transactionEnded = true }
        }
    }

    // Found idle at the import's end with nothing kept: the file rolled the transaction back, or the server ended it.
    // Read inside `lock`, which is not recursive.
    private var endedBeforeTheImportLocked: ImportTransactionEnding {
        fileEndedTransaction ? .rolledBack : .endedByServer
    }

    // `SET sql_mode` changes how the next statement reads. A COMMIT, a ROLLBACK or a DDL statement can end the import's
    // transaction early, and a write after that runs on its own and stays, so each is read as it lands.
    private func noteEffects(of statement: String) async {
        let keyword = ExportSnapshotStatements.leadingKeyword(of: statement)
        if keyword == "SET" {
            _ = await driver.sessionLexicalFacts()
        }
        guard holdsOwnTransaction || joinsUserTransaction else { return }
        let endedBefore = lock.withLock { fileEndedTransaction }
        let mayEnd = Self.transactionEndKeywords.contains(keyword) || Self.ddlKeywords.contains(keyword)
        let writes = endedBefore && SQLWriteClassifier.isWriteQuery(statement, databaseType: databaseType)
        guard mayEnd || writes, await driver.sessionTransactionState() == .idle else { return }
        lock.withLock {
            if endedBefore {
                keptWrites = keptWrites || writes
            } else {
                fileEndedTransaction = true
                fileRolledBack = keyword == "ROLLBACK"
                if keyword != "ROLLBACK" { keptWrites = true }
            }
        }
    }

    private static let transactionEndKeywords: Set<String> = ["COMMIT", "END", "ROLLBACK"]

    func copyFromStandardInput(statement: String, line: Int, rows: PluginCopyData) async throws {
        try admitWrite()
        guard let copier = driver as? any CopyFromStandardInputDriving else {
            throw SQLFileParseError.copyFromStandardInput(line: line)
        }
        _ = try await copier.copyFromStandardInput(statement: statement, rows: rows)
    }

    // MARK: - Rows

    func insertRow(_ values: [String: PluginCellValue]) async throws {
        try await clearTargetIfDue()
        let (writer, target) = try await writing()
        try await writer.insertRow(values, into: target, host: host)
    }

    func insertRows(_ rows: [[String: PluginCellValue]]) async throws {
        try await clearTargetIfDue()
        let (writer, target) = try await writing()
        try await writer.insertRows(rows, into: target, host: host)
    }

    func deleteAllRowsFromTargetTable() async throws {
        let (writer, target) = try await writing()
        let statement = try writer.clearingStatement(using: target.statements)
        _ = try await driver.execute(query: statement)
        lock.withLock { clearedTarget = true }
    }

    // Before the first row when no transaction was begun, and by the run when a successful import wrote none.
    func clearTargetIfDue() async throws {
        guard lock.withLock({ clearsTargetFirst && !clearedTarget }) else { return }
        try await deleteAllRowsFromTargetTable()
    }

    func mappedColumnsAndValues(_ values: [String: PluginCellValue]) -> ([String], [PluginCellValue]) {
        rowWriter?.mappedColumnsAndValues(values) ?? ([], [])
    }

    private func writing() async throws -> (ImportRowWriter, ImportRowWriter.Target) {
        try admitWrite()
        guard let rowWriter, let rowTarget else {
            throw PluginImportError.importFailed(String(localized: "No target table configured for row import"))
        }
        if let known = lock.withLock({ writerTarget }) { return (rowWriter, known) }
        guard let dialect else {
            throw MobileTransferRefusal(reason: String(
                format: String(localized: "%@ cannot take rows from a file."), databaseType.mobileDisplayName
            ))
        }
        let columns = try await driver.fetchColumns(table: rowTarget.table, schema: rowTarget.schema, database: rowTarget.database)
        let statements = try await dialect.importStatements(table: rowTarget.table, schema: rowTarget.schema, columns: columns)
        let target = ImportRowWriter.Target(
            tableName: rowTarget.table,
            statements: statements,
            values: ImportTargetValues(columns: columns, databaseType: databaseType, binaryText: rowTarget.binaryText)
        )
        lock.withLock { writerTarget = target }
        return (rowWriter, target)
    }

    private var host: ImportRowWriter.Host {
        ImportRowWriter.Host(
            execute: { statement, purpose in try await self.send(statement, purpose) },
            columnsUpdateCannotSet: { try await self.columnsUpdateCannotSet() },
            isCancelled: { [weak self] in self?.isStopped ?? true }
        )
    }

    private func send(_ statement: SQLImportStatement, _ purpose: ImportRowWriter.Purpose) async throws -> [[String?]] {
        let result = try await driver.executeParameterized(
            query: statement.sql, parameters: statement.parameters, typeNames: statement.parameterTypeNames
        )
        switch purpose {
        case .matchProbe:
            return result.rows
        case .write:
            return []
        }
    }

    private func columnsUpdateCannotSet() async throws -> Set<String> {
        if let known = lock.withLock({ immutableColumns }) { return known }
        guard let dialect, let rowTarget else { return [] }
        let fetched = try await dialect.columnsUpdateCannotSet(table: rowTarget.table, schema: rowTarget.schema)
        lock.withLock { immutableColumns = fetched }
        return fetched
    }
}

nonisolated extension ImportTargetValues {
    init(columns: [ColumnInfo], databaseType: DatabaseType, binaryText: ImportBinaryText?) {
        self.init(
            columns: columns.map { (name: $0.name, typeName: $0.typeName, isGenerated: $0.isServerOwned) },
            databaseTypeId: databaseType.rawValue,
            writesNumericBooleans: Self.writesNumericBooleans(databaseType),
            binaryText: binaryText
        )
    }

    // Each driver plugin's `booleanLiteralStyle`, which iOS has no plugin bundle to ask: PostgreSQL's, which Redshift
    // shares, and DuckDB's write `true` and `false`.
    static func writesNumericBooleans(_ databaseType: DatabaseType) -> Bool {
        ![DatabaseType.postgresql, .redshift, .duckdb].contains(databaseType)
    }
}

nonisolated extension ImportMatchKey {
    static func options(columns: [ColumnInfo], indexes: [IndexInfo]) -> [ImportMatchKey] {
        options(
            columns: columns.map { ImportMatchKey.Column(name: $0.name, isPrimaryKey: $0.isPrimaryKey) },
            indexes: indexes.map(ImportMatchKey.Index.init(mobile:))
        )
    }
}

nonisolated extension ImportMatchKey.Index {
    // The iOS catalog says nothing of validity or expressions, so an index reads as a plain valid one.
    init(mobile index: IndexInfo) {
        self.init(
            name: index.name,
            columns: index.columns,
            isUnique: index.isUnique,
            isPrimary: index.isPrimary,
            isPartial: !(index.whereClause ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }
}
