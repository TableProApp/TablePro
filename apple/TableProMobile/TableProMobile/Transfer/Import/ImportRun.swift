import Foundation
import os
import TableProDatabase
import TableProModels
import TableProPluginKit
import TableProSQLGrammar

nonisolated struct RowImportTarget: Sendable {
    let table: String
    let schema: String?
    // Field to column, for every field the user kept.
    let columnMapping: [String: String]
    // Every field the file holds, in file order.
    let sourceFields: [String]
    let rowWriting: ImportRowWriting
    // Set when the rows go into a table the import makes first.
    let newTable: PluginCreateTableDefinition?

    init(
        table: String,
        schema: String?,
        columnMapping: [String: String],
        sourceFields: [String],
        rowWriting: ImportRowWriting = .insert,
        newTable: PluginCreateTableDefinition? = nil
    ) {
        self.table = table
        self.schema = schema
        self.columnMapping = columnMapping
        self.sourceFields = sourceFields
        self.rowWriting = rowWriting
        self.newTable = newTable
    }
}

nonisolated struct ImportRequest: Sendable {
    let formatId: String
    let file: StagedImportFile
    let connectionId: UUID
    let connectionName: String
    let databaseType: DatabaseType
    let database: String?
    let safeModeLevel: SafeModeLevel
    let target: RowImportTarget?
    let sqlEncoding: String.Encoding

    init(
        formatId: String,
        file: StagedImportFile,
        connectionId: UUID,
        connectionName: String,
        databaseType: DatabaseType,
        database: String?,
        safeModeLevel: SafeModeLevel,
        target: RowImportTarget?,
        sqlEncoding: String.Encoding = .utf8
    ) {
        self.formatId = formatId
        self.file = file
        self.connectionId = connectionId
        self.connectionName = connectionName
        self.databaseType = databaseType
        self.database = database
        self.safeModeLevel = safeModeLevel
        self.target = target
        self.sqlEncoding = sqlEncoding
    }

    // The level the user confirmed under, read live from the connection when they did.
    func confirmed(under level: SafeModeLevel) -> ImportRequest {
        ImportRequest(
            formatId: formatId, file: file, connectionId: connectionId, connectionName: connectionName,
            databaseType: databaseType, database: database, safeModeLevel: level, target: target, sqlEncoding: sqlEncoding
        )
    }
}

nonisolated struct ImportStopQuestion: Sendable, Equatable {
    // "Stop and Commit" beside "Stop and Rollback" only while the import holds a transaction of its own.
    let offersCommit: Bool
    let message: String
}

nonisolated struct DataImportOutcome: Sendable {
    nonisolated enum Ending: Sendable, Equatable {
        case completed
        case stopped
        case expired
        case failed(String)
    }

    let ending: Ending
    let transaction: ImportTransactionEnding
    let tally: ImportRowTally?
    let executedStatements: Int
    let skippedStatements: Int
    let errors: [PluginImportResult.ImportStatementError]
    let createdTable: Bool
    let catalogChanges: SQLCatalogObjectKinds
    // What a SQL file's statements left on the session, for the window to follow as it follows a query run.
    var sessionEffect = SessionLocalStatements.Effect()
    var endsTransaction = false

    var summaryLines: [String] {
        if let tally {
            return tally.summaryLines(failed: errors.count)
        }
        var lines = [String(format: String(localized: "Statements run: %@"), executedStatements.formatted())]
        if skippedStatements > 0 {
            lines.append(String(format: String(localized: "Statements skipped: %@"), skippedStatements.formatted()))
        }
        return lines
    }

    // Whether the host should check the session is still there: an error mid-run, a statement skipped on one, or the
    // server ending the transaction. An expired run may have closed the session itself, and the next use dials again.
    var mayHaveLostSession: Bool {
        switch ending {
        case .failed:
            return true
        case .completed:
            return !errors.isEmpty || transaction == .endedByServer
        case .stopped:
            return transaction == .endedByServer
        case .expired:
            return false
        }
    }

    // What happened to the rows, said only where it is not simply "the import finished and committed".
    var transactionMessage: String? {
        switch (transaction, ending) {
        case (.leftInOpenTransaction, _):
            return ImportRun.joinedTransactionMessage
        case (.committed, .completed), (.none, .completed):
            return nil
        case (.rolledBack, _):
            return String(localized: "The import's transaction was rolled back, so none of its rows were kept.")
        case (.committed, _):
            return String(localized: "The rows written before the import ended were committed.")
        case (.partlyCommitted, _):
            return String(localized: "The file ended the import's transaction early, so the rows written before that stay.")
        case (.none, _):
            return String(localized: "The rows written before the import ended stay in the table.")
        case (.endedByServer, _):
            return String(localized: "The database had already ended the import's transaction, so none of its rows were kept.")
        }
    }
}

// Tables one import sheet made, so its retry clears and reuses its own table rather than failing on the name or writing
// the kept rows a second time. Another sheet never counts as a retry (macOS `RowImportSheet`).
nonisolated final class ImportTablePlanner: @unchecked Sendable {
    private let lock = NSLock()
    private var planner = NewTableImportPlanner()

    func plan(for table: NewTableImportPlanner.Table, createTableSQL: String) -> NewTableImportPlan {
        lock.withLock { planner.plan(for: table, createTableSQL: createTableSQL) }
    }

    func recordCreated(_ table: NewTableImportPlanner.Table, createTableSQL: String) {
        lock.withLock { planner.recordCreated(table, createTableSQL: createTableSQL) }
    }
}

// The iOS counterpart of macOS `ImportService` for one file: runs the format plugin on the window's session inside the
// coordinator's tracking, with one safe-mode decision for the whole run (made by the caller's `ConfirmedWriteGate`).
nonisolated final class ImportRun: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ImportRun")

    static var joinedTransactionMessage: String {
        String(localized: "The rows written stay in the transaction that is open on this connection. Commit or roll it back.")
    }

    private let request: ImportRequest
    private let plugin: any ImportFormatPlugin
    private let host: any TransferSessionHost
    private let background: TransferBackgroundRun?
    private let planner: ImportTablePlanner
    private let rollbackGrace: Duration

    private let lock = NSLock()
    private var stopChoice: ImportStopChoice?
    private var expired = false
    private var finished = false
    private var sink: MobileImportDataSink?
    private var sqlSource: MobileSQLFileImportSource?
    private var pluginProgress: PluginImportProgress?

    init(
        request: ImportRequest,
        plugin: any ImportFormatPlugin,
        host: any TransferSessionHost,
        background: TransferBackgroundRun? = nil,
        planner: ImportTablePlanner = ImportTablePlanner(),
        rollbackGrace: Duration = .milliseconds(1_500)
    ) {
        self.request = request
        self.plugin = plugin
        self.host = host
        self.background = background
        self.planner = planner
        self.rollbackGrace = rollbackGrace
    }

    // Read-Only refuses every import; an engine that takes no rows, or a format it does not read, is refused by name.
    static func refusal(
        connectionName: String,
        databaseType: DatabaseType,
        safeModeLevel: SafeModeLevel,
        formatId: String
    ) -> String? {
        guard !safeModeLevel.blocksWrites else {
            return String(format: String(localized: "%@ is read-only, so nothing can be written to it."), connectionName)
        }
        guard databaseType.speaksSQL else {
            return String(format: String(localized: "Import is not supported for %@ connections."), databaseType.mobileDisplayName)
        }
        guard let plugin = MobileImportFormats.plugin(formatId: formatId) else {
            return String(format: String(localized: "%@ files cannot be imported into this connection."), formatId.uppercased())
        }
        let offered = type(of: plugin).requiresTargetTable
            ? MobileImportFormats.rowFormats(for: databaseType).contains { type(of: $0).formatId == formatId }
            : MobileImportFormats.offersSQLFile(for: databaseType)
        guard offered else {
            return String(
                format: String(localized: "%@ files cannot be imported into this connection."),
                type(of: plugin).formatDisplayName
            )
        }
        return nil
    }

    // MARK: - Stop

    var stopQuestion: ImportStopQuestion {
        let sink = lock.withLock { self.sink }
        if sink?.holdsOwnTransaction == true {
            return ImportStopQuestion(
                offersCommit: true,
                message: String(localized: "Roll back to remove the rows written so far, or commit to keep them.")
            )
        }
        if sink?.joinsUserTransaction == true {
            return ImportStopQuestion(offersCommit: false, message: Self.joinedTransactionMessage)
        }
        return ImportStopQuestion(
            offersCommit: false,
            message: String(localized: "The rows written so far stay in the table.")
        )
    }

    // Latched: the first choice wins, and a stop before the run starts keeps it from writing at all. It also stops a
    // `.gz` still expanding.
    func stop(_ choice: ImportStopChoice) {
        let targets = lock.withLock { () -> StopTargets in
            if stopChoice == nil { stopChoice = choice }
            return StopTargets(sink: sink, progress: pluginProgress, source: sqlSource)
        }
        targets.sink?.stop(choice)
        targets.progress?.cancel()
        targets.source?.stop()
    }

    nonisolated private struct StopTargets {
        let sink: MobileImportDataSink?
        let progress: PluginImportProgress?
        let source: MobileSQLFileImportSource?
    }

    // Background time ran out. An owned rollback that has not reached the server before the grace ends the connection,
    // so the server ends the transaction rather than holding its locks while the phone sleeps (critic M8).
    func expire() {
        lock.withLock { expired = true }
        stop(.rollBack)
        let grace = rollbackGrace
        let host = host
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard let self else { return }
            let stalled = self.lock.withLock { !self.finished && self.sink?.holdsOwnTransaction == true }
            guard stalled else { return }
            Self.logger.warning("The import's rollback did not finish before background time ran out; closing the session")
            await host.abandonTransferSession()
        }
    }

    private var isStopped: Bool {
        lock.withLock { stopChoice != nil }
    }

    // MARK: - Run

    // Throws only before any row is written: `MobileTransferRefusal` for a refused import or a table that could not be
    // made, `CancellationError` for one stopped before it began, the session's `AppError` when there is none.
    // Everything after the first row comes back as an outcome.
    @concurrent
    func run(onProgress: @escaping @Sendable (TransferProgress) -> Void) async throws -> DataImportOutcome {
        if let reason = Self.refusal(
            connectionName: request.connectionName,
            databaseType: request.databaseType,
            safeModeLevel: request.safeModeLevel,
            formatId: request.formatId
        ) {
            throw MobileTransferRefusal(reason: reason)
        }
        guard !isStopped else { throw CancellationError() }

        await background?.begin { [weak self] in self?.expire() }
        let report: @Sendable (TransferProgress) -> Void = { [background] progress in
            onProgress(progress)
            guard let background else { return }
            Task { @MainActor in background.report(progress) }
        }
        do {
            // A refusal is carried out of the tracked work as a value: thrown through it, the coordinator would treat it
            // as a session lost mid-write and redial. A failed run is a value too, and `failed` hands it to that check.
            let performed = try await admitted { [self] (admission: ImportAdmission) async throws -> Performed in
                if let reason = self.admissionRefusal(liveLevel: admission.safeModeLevel) {
                    return .refused(MobileTransferRefusal(reason: reason))
                }
                do {
                    return .outcome(try await self.perform(on: admission.driver, report: report), on: admission.driver)
                } catch let refusal as MobileTransferRefusal {
                    return .refused(refusal)
                } catch is CancellationError {
                    return .cancelled
                }
            }
            lock.withLock { finished = true }
            let outcome: DataImportOutcome
            let driver: any DatabaseDriver
            switch performed {
            case .outcome(let value, let ranOn):
                outcome = value
                driver = ranOn
            case .refused(let refusal):
                throw refusal
            case .cancelled:
                throw CancellationError()
            }
            // A SQL file may have run `USE` or moved the search path, however it ended.
            let followsSession = request.target == nil
            if followsSession {
                await host.noteTransferSessionEffect(outcome.sessionEffect, on: driver)
            }
            if !outcome.catalogChanges.isEmpty {
                await host.noteTransferChangedCatalog(outcome.catalogChanges)
            }
            if followsSession {
                await host.followTransferPlacement(
                    movesDatabase: outcome.sessionEffect.usesDatabase,
                    movesSchema: outcome.sessionEffect.leavesCatalog || outcome.endsTransaction
                )
            }
            await background?.end(success: outcome.ending == .completed)
            return outcome
        } catch {
            lock.withLock { finished = true }
            await background?.end(success: false)
            throw error
        }
    }

    // The session is the import's for the whole run or not at all: another import, other work or a session that is
    // moving refuses it at once, and nothing waits.
    private func admitted(_ work: @escaping @Sendable (ImportAdmission) async throws -> Performed) async throws -> Performed {
        do {
            return try await host.trackImport(failed: { (performed: Performed) in performed.mayHaveLostSession }, work)
        } catch let held as SessionHeldByImport {
            throw MobileTransferRefusal(reason: held.localizedDescription)
        } catch let busy as SessionBusyForImport {
            throw MobileTransferRefusal(reason: busy.localizedDescription)
        }
    }

    // Safe Mode read again as the run is admitted: a level another window made stricter since the confirmation wins.
    private func admissionRefusal(liveLevel: SafeModeLevel) -> String? {
        if let reason = Self.refusal(
            connectionName: request.connectionName,
            databaseType: request.databaseType,
            safeModeLevel: liveLevel,
            formatId: request.formatId
        ) {
            return reason
        }
        guard liveLevel.requiresConfirmation, !request.safeModeLevel.requiresConfirmation else { return nil }
        return String(localized: "Safe Mode on this connection changed. Start the import again.")
    }

    nonisolated private enum Performed: Sendable {
        case outcome(DataImportOutcome, on: any DatabaseDriver)
        case refused(MobileTransferRefusal)
        case cancelled

        var mayHaveLostSession: Bool {
            guard case .outcome(let outcome, _) = self else { return false }
            return outcome.mayHaveLostSession
        }
    }

    @concurrent
    private func perform(
        on driver: any DatabaseDriver,
        report: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> DataImportOutcome {
        report(TransferProgress(stage: .preparing, unit: request.target == nil ? .statements : .rows))
        let dialect = try await writeDialect(on: driver)
        try await refuseIfSessionMoved(on: driver, dialect: dialect)
        var catalogChanges: SQLCatalogObjectKinds = request.target == nil ? .everything : []
        let preparation = try await prepareNewTable(on: driver, dialect: dialect)
        if preparation.created { catalogChanges.insert(.tables) }

        let host = host
        let catalogHold = request.target == nil ? ImportCatalogHold(
            hold: { await host.holdTransferCatalogConnections() },
            release: { await host.releaseTransferCatalogConnections() }
        ) : nil
        let sink = MobileImportDataSink(
            driver: driver,
            databaseType: request.databaseType,
            rowTarget: request.target.map { target in
                MobileImportDataSink.RowTarget(
                    table: target.table,
                    schema: target.schema,
                    columnMapping: target.columnMapping,
                    sourceFields: Set(target.sourceFields),
                    rowWriting: target.rowWriting,
                    binaryText: ImportBinaryText(formatId: request.formatId),
                    database: request.database
                )
            },
            dialect: dialect,
            clearsTargetFirst: preparation.clearsFirst,
            catalogHold: catalogHold
        )
        let shared = SharedProgress(Progress(totalUnitCount: 0))
        let progress = PluginImportProgress(progress: shared.progress)
        let stopped = lock.withLock { () -> ImportStopChoice? in
            self.sink = sink
            pluginProgress = progress
            return stopChoice
        }
        if let stopped {
            sink.stop(stopped)
            progress.cancel()
        }

        let bytes = ImportBytesRead()
        let source = makeSource(on: driver, bytes: bytes)
        if let sqlFile = source as? MobileSQLFileImportSource {
            let stoppedBefore = lock.withLock { () -> Bool in
                sqlSource = sqlFile
                return stopChoice != nil
            }
            if stoppedBefore { sqlFile.stop() }
        }
        let fileSize = request.file.fileSize
        let unit: TransferProgress.Unit = request.target == nil ? .statements : .rows
        let read: @Sendable () -> TransferProgress = {
            var running = TransferProgress(stage: .running, unit: unit)
            running.completedUnits = progress.processedStatements
            running.totalUnits = progress.estimatedTotalStatements > 0 ? progress.estimatedTotalStatements : nil
            running.status = shared.status
            let file = bytes.value
            running.bytesRead = file.bytesRead
            running.totalBytes = file.fileSize ?? (fileSize > 0 ? fileSize : nil)
            return running
        }
        let poller = TransferProgressPoller()
        poller.start(read: read, report: report)

        var result: PluginImportResult?
        var failure: (any Error)?
        do {
            result = try await plugin.performImport(source: source, sink: sink, progress: progress)
            if lock.withLock({ stopChoice }) == nil {
                try await sink.clearTargetIfDue()
            }
        } catch {
            failure = error
        }
        source.cleanup()

        var finishing = read()
        finishing.stage = .finishing
        poller.stop(final: finishing, report: report)

        let choice = lock.withLock { stopChoice }
        await sink.finish(commit: choice == .commit || (failure == nil && choice == nil))
        await catalogHold?.releaseIfHeld()
        let transaction = await sink.transactionEnding()

        return DataImportOutcome(
            ending: ending(failure: failure, choice: choice),
            transaction: transaction,
            tally: request.target == nil ? nil : sink.rowTally,
            executedStatements: result?.executedStatements ?? progress.processedStatements,
            skippedStatements: result?.skippedStatements ?? 0,
            errors: result?.errors ?? [],
            createdTable: preparation.created,
            catalogChanges: catalogChanges,
            sessionEffect: sink.sessionEffect,
            endsTransaction: sink.endedTransaction
        )
    }

    private func ending(failure: (any Error)?, choice: ImportStopChoice?) -> DataImportOutcome.Ending {
        if lock.withLock({ expired }) { return .expired }
        if choice != nil { return .stopped }
        guard let failure else { return .completed }
        if failure is PluginImportCancellationError || failure is CancellationError { return .stopped }
        return .failed(failure.localizedDescription)
    }

    private func writeDialect(on driver: any DatabaseDriver) async throws -> (any MobileWriteDialect)? {
        guard let target = request.target else { return nil }
        guard let engine = driver as? any MobileTransferEngine else {
            throw MobileTransferRefusal(reason: String(
                format: String(localized: "%@ cannot take rows from a file."), request.databaseType.mobileDisplayName
            ))
        }
        return try await engine.makeWriteDialect(context: MobileTransferContext(
            databaseType: request.databaseType, database: request.database, schema: target.schema
        ))
    }

    // The sheet named its database, and another window can have moved the session since. Rows that name the database
    // land there anyway; anything that does not, a new table among them, is refused rather than written elsewhere.
    private func refuseIfSessionMoved(on driver: any DatabaseDriver, dialect: (any MobileWriteDialect)?) async throws {
        guard let target = request.target, let wanted = request.database, !wanted.isEmpty else { return }
        if dialect?.namesDatabase == true, target.newTable == nil { return }
        let current: String?
        if let reporting = driver as? any SessionDatabaseReporting {
            current = try? await reporting.sessionDatabase()
        } else {
            current = await host.transferDatabase
        }
        guard let current, !current.isEmpty, current != wanted else { return }
        throw MobileTransferRefusal(reason: Self.sessionMovedMessage)
    }

    static var sessionMovedMessage: String {
        String(localized: "The connection moved to another database or schema. Choose the table again.")
    }

    nonisolated private struct NewTablePreparation {
        var created = false
        var clearsFirst = false
    }

    // The table is made before the rows and committed on its own, as macOS `RowImportTableMaker` does, so a stopped
    // import never rolls back the table the user asked for.
    private func prepareNewTable(
        on driver: any DatabaseDriver,
        dialect: (any MobileWriteDialect)?
    ) async throws -> NewTablePreparation {
        guard let target = request.target, let definition = target.newTable, let dialect else {
            return NewTablePreparation()
        }
        let statements = try dialect.createTableStatements(definition: definition, schema: target.schema)
        let createSQL = statements.joined(separator: "\n")
        let key = NewTableImportPlanner.Table(
            connectionId: request.connectionId, database: request.database, schema: target.schema, name: definition.tableName
        )
        switch planner.plan(for: key, createTableSQL: createSQL) {
        case .reuseAfterClearing:
            return NewTablePreparation(created: false, clearsFirst: true)
        case .nameTakenWithDifferentColumns:
            throw MobileTransferRefusal(reason: String(
                format: String(localized: "An earlier import made a table named %@ with other columns. Choose another name."),
                definition.tableName
            ))
        case .create:
            break
        }
        switch await driver.sessionTransactionState() {
        case .explicitTransaction, .implicitTransaction, .abortedTransaction:
            throw MobileTransferRefusal(reason: String(
                localized: "Commit or roll back the transaction open on this connection before importing into a new table."
            ))
        case .idle, .unknown:
            break
        }
        guard !isStopped else { throw CancellationError() }
        do {
            for statement in statements {
                _ = try await driver.execute(query: statement)
            }
        } catch {
            throw MobileTransferRefusal(reason: error.localizedDescription)
        }
        planner.recordCreated(key, createTableSQL: createSQL)
        return NewTablePreparation(created: true, clearsFirst: false)
    }

    private func makeSource(on driver: any DatabaseDriver, bytes: ImportBytesRead) -> any PluginImportSource {
        guard request.target == nil else {
            return PlainFileImportSource(url: request.file.url)
        }
        let databaseType = request.databaseType
        let source = MobileSQLFileImportSource(
            url: request.file.url,
            encoding: request.sqlEncoding,
            family: SQLImportFile.dumpFamily(for: databaseType),
            grammar: { SQLImportFile.grammar(for: databaseType, session: driver.settledLexicalFacts) }
        )
        source.reportsReading { read, size in bytes.update(read: read, size: size) }
        return source
    }
}

nonisolated private final class ImportBytesRead: @unchecked Sendable {
    private let lock = NSLock()
    private var bytesRead: Int64?
    private var fileSize: Int64?

    func update(read: Int64, size: Int64) {
        lock.withLock {
            bytesRead = read
            fileSize = size > 0 ? size : nil
        }
    }

    var value: (bytesRead: Int64?, fileSize: Int64?) {
        lock.withLock { (bytesRead, fileSize) }
    }
}
