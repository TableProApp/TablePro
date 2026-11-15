import Foundation
import os
import TableProDatabase
import TableProLogRedaction
import TableProModels
import TableProPluginKit

// A read the app builds, written for the connection that runs it: an export reads on a connection of its own, whose
// literal rules (MySQL's NO_BACKSLASH_ESCAPES, PostgreSQL's standard_conforming_strings) can differ from the window's.
nonisolated struct ExportSelect: Sendable, ExpressibleByStringLiteral {
    private let render: @Sendable (any DatabaseDriver) -> String

    init(render: @escaping @Sendable (any DatabaseDriver) -> String) {
        self.render = render
    }

    init(stringLiteral sql: String) {
        render = { _ in sql }
    }

    func statement(on driver: any DatabaseDriver) -> String {
        render(driver)
    }
}

nonisolated enum ExportSource: Sendable {
    // Objects of one database, from `ExportObjectListing`, with the option values the user chose.
    case objects([PluginExportTable])
    // A read statement the app built, run again in full: a filtered or sorted table, or rows read again by key.
    case query(ExportSelect)
    // The user's statement run again for a query's whole result, only in the engine's read-only mode: the classifier
    // calls `SELECT post_payment(42)` a read, and its function writes.
    case rerun(String)
    // Rows already held: selected rows with no key, or a result that cannot run again in read-only mode.
    case rows(ExportRowSet)
}

nonisolated struct ExportRequest: Sendable {
    let formatId: String
    let source: ExportSource
    let fileName: String
    let connectionId: UUID
    let databaseType: DatabaseType
    let database: String?
    let schema: String?
    let safeModeLevel: SafeModeLevel
    // Spells the literals of a `.rows` export the way the session reads them.
    let sessionDriver: (any DatabaseDriver)?

    init(
        formatId: String,
        source: ExportSource,
        fileName: String,
        connectionId: UUID,
        databaseType: DatabaseType,
        database: String?,
        schema: String?,
        safeModeLevel: SafeModeLevel,
        sessionDriver: (any DatabaseDriver)? = nil
    ) {
        self.formatId = formatId
        self.source = source
        self.fileName = fileName
        self.connectionId = connectionId
        self.databaseType = databaseType
        self.database = database
        self.schema = schema
        self.safeModeLevel = safeModeLevel
        self.sessionDriver = sessionDriver
    }
}

nonisolated struct ExportOutcome: Sendable {
    let folder: URL
    let files: [URL]
    let rowsWritten: Int
    let warnings: [String]
    let notes: [String]

    func discard() {
        TransferFiles.remove(folder)
    }
}

nonisolated protocol ExportRunning: AnyObject, Sendable {
    func run(onProgress: @escaping @Sendable (TransferProgress) -> Void) async throws -> ExportOutcome
    func cancel()
}

// The iOS counterpart of macOS `ExportService`: one format, one source, one file in a folder of its own. A stop, a
// failure or an expiry leaves no folder behind.
nonisolated final class ExportRun: ExportRunning, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ExportRun")

    private let request: ExportRequest
    private let plugin: any ExportFormatPlugin
    private let drivers: any TransferDriverProvider
    private let background: TransferBackgroundRun?
    private let sessionHost: (any TransferSessionHost)?
    private let exportsRoot: URL
    private let stopGrace: Duration

    private let lock = NSLock()
    private var stopRequested = false
    private var pluginProgress: PluginExportProgress?
    private var heldLease: TransferDriverLease?
    private var writingFolder: URL?
    private var work: Task<Void, Never>?
    private var ending: FirstResult<ExportOutcome>?

    // `stopGrace` bounds how long a stop waits for the driver to stop its statement before the connection is closed
    // anyway: a dedicated connection has no query timeout, and a driver like Redis cannot cancel at all.
    init(
        request: ExportRequest,
        plugin: any ExportFormatPlugin,
        drivers: any TransferDriverProvider,
        background: TransferBackgroundRun? = nil,
        sessionHost: (any TransferSessionHost)? = nil,
        exportsRoot: URL = TransferFiles.exportsDirectory,
        stopGrace: Duration = .seconds(2)
    ) {
        self.request = request
        self.plugin = plugin
        self.drivers = drivers
        self.background = background
        self.sessionHost = sessionHost
        self.exportsRoot = exportsRoot
        self.stopGrace = stopGrace
    }

    // `sessionHost` tracks an export that ends up reading on the window's own session, as a SQLite file holding the
    // user's transaction does, so the grid waits for it rather than ending its stream.
    convenience init(
        request: ExportRequest,
        plugin: any ExportFormatPlugin,
        connectionManager: ConnectionManager,
        background: TransferBackgroundRun? = nil,
        sessionHost: (any TransferSessionHost)? = nil
    ) {
        self.init(
            request: request,
            plugin: plugin,
            drivers: DedicatedTransferDriverProvider(
                connectionManager: connectionManager, connectionId: request.connectionId, database: request.database
            ),
            background: background,
            sessionHost: sessionHost
        )
    }

    // Latched, so a stop during the count or before the plugin starts is not lost. The run ends here and now, the
    // background expiry included: the work is cancelled, the driver is asked to stop its statement, and the connection
    // is released within `stopGrace` even when a read never returns.
    func cancel() {
        let stop = lock.withLock { () -> StopTargets in
            stopRequested = true
            defer { heldLease = nil }
            return StopTargets(
                progress: pluginProgress, work: work, ending: ending, lease: heldLease, folder: writingFolder
            )
        }
        stop.progress?.cancel()
        stop.work?.cancel()
        // Only a stop that ended the run removes the folder: a run that finished first hands its file to the caller.
        if stop.ending?.settle(.failure(CancellationError())) == true, let folder = stop.folder {
            TransferFiles.remove(folder)
        }
        // The window's own session is never closed, and a blind stop there could reach the user's next statement; the
        // cancelled work ends its own stream on it.
        if let lease = stop.lease, !lease.isSessionDriver {
            stopAndRelease(lease)
        }
    }

    nonisolated private struct StopTargets {
        let progress: PluginExportProgress?
        let work: Task<Void, Never>?
        let ending: FirstResult<ExportOutcome>?
        let lease: TransferDriverLease?
        let folder: URL?
    }

    var isCancelled: Bool {
        lock.withLock { stopRequested }
    }

    private func throwIfStopped() throws {
        if isCancelled || Task.isCancelled { throw CancellationError() }
    }

    @concurrent
    func run(onProgress: @escaping @Sendable (TransferProgress) -> Void) async throws -> ExportOutcome {
        try throwIfStopped()
        await background?.begin { [weak self] in self?.cancel() }
        let report: @Sendable (TransferProgress) -> Void = { [background] progress in
            onProgress(progress)
            guard let background else { return }
            Task { @MainActor in background.report(progress) }
        }
        do {
            let outcome = try await performUntilStopped(report: report)
            await background?.end(success: true)
            return outcome
        } catch {
            await background?.end(success: false)
            if error is CancellationError || error is PluginExportCancellationError || isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    // MARK: - Run

    // The work runs in a task of its own, so a stop returns at once even while a driver keeps reading; whatever the
    // work finishes with after that is thrown away.
    private func performUntilStopped(
        report: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> ExportOutcome {
        let ending = FirstResult<ExportOutcome>()
        let work = Task { [self] in
            do {
                let outcome = try await perform(report: report)
                if !ending.settle(.success(outcome)) { outcome.discard() }
            } catch {
                ending.settle(.failure(error))
            }
        }
        let stopped = lock.withLock { () -> Bool in
            self.work = work
            self.ending = ending
            return stopRequested
        }
        if stopped { cancel() }
        return try await withTaskCancellationHandler {
            try await ending.value()
        } onCancel: { [weak self] in
            self?.cancel()
        }
    }

    private func perform(report: @escaping @Sendable (TransferProgress) -> Void) async throws -> ExportOutcome {
        var preparing = TransferProgress(stage: .preparing)
        preparing.objectCount = objectCount
        report(preparing)

        let lease: TransferDriverLease?
        switch request.source {
        case .objects, .query, .rerun:
            lease = try await hold(try await drivers.openTransferDriver())
        case .rows:
            lease = nil
        }
        do {
            try await lease?.settle(schema: request.schema)
            let outcome: ExportOutcome
            if let lease, lease.isSessionDriver, let sessionHost {
                // Carried out as a value: an error thrown through the tracking would read as a session lost mid-write.
                let result = try await sessionHost.trackTransfer { [self] () async throws -> Result<ExportOutcome, any Error> in
                    do {
                        return .success(try await self.export(on: lease, report: report))
                    } catch {
                        return .failure(error)
                    }
                }
                outcome = try result.get()
            } else {
                outcome = try await export(on: lease, report: report)
            }
            await releaseHeldLease()
            return outcome
        } catch {
            await releaseHeldLease()
            throw error
        }
    }

    // Kept where a stop can reach it. A stop that came while the connection opened closes it before anything reads.
    private func hold(_ lease: TransferDriverLease) async throws -> TransferDriverLease {
        let stopped = lock.withLock { () -> Bool in
            if !stopRequested { heldLease = lease }
            return stopRequested
        }
        guard !stopped else {
            await lease.close()
            throw CancellationError()
        }
        return lease
    }

    // Closed once, by whichever of the run's end and a stop comes first.
    private func releaseHeldLease() async {
        let lease = lock.withLock { () -> TransferDriverLease? in
            defer { heldLease = nil }
            return heldLease
        }
        await lease?.close()
    }

    private func stopAndRelease(_ lease: TransferDriverLease) {
        let grace = stopGrace
        let driver = lease.driver
        let stopping = Task { _ = try? await driver.cancelCurrentQuery() }
        Task {
            let settled = FirstResult<Void>()
            Task {
                await stopping.value
                settled.settle(.success(()))
            }
            Task {
                try? await Task.sleep(for: grace)
                settled.settle(.success(()))
            }
            try? await settled.value()
            await lease.close()
        }
    }

    private var objectCount: Int {
        if case .objects(let objects) = request.source { return objects.count }
        return 1
    }

    @concurrent
    private func export(
        on lease: TransferDriverLease?,
        report: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> ExportOutcome {
        let readOnly = request.safeModeLevel.blocksWrites
        let (dataSource, tables, total) = try await prepare(on: lease, readOnly: readOnly, report: report)
        try throwIfStopped()

        let folder = try openFolder()
        do {
            let destination = TransferFiles.fileURL(
                in: folder, name: request.fileName, fileExtension: plugin.currentFileExtension
            )
            let result = try await write(tables: tables, dataSource: dataSource, to: destination, total: total, report: report)
            // A plugin that returns after a stop has still written the file the user said to throw away.
            try throwIfStopped()
            return ExportOutcome(
                folder: folder,
                files: TransferFiles.writtenFiles(in: folder, primary: destination),
                rowsWritten: result.rows,
                warnings: result.format.warnings,
                notes: result.format.notes
            )
        } catch {
            TransferFiles.remove(folder)
            throw error
        }
    }

    // Known to a stop, which removes it when it ends the run before the plugin returns.
    private func openFolder() throws -> URL {
        let folder = try TransferFiles.makeExportFolder(in: exportsRoot)
        let stopped = lock.withLock { () -> Bool in
            writingFolder = folder
            return stopRequested
        }
        guard !stopped else {
            TransferFiles.remove(folder)
            throw CancellationError()
        }
        return folder
    }

    private func prepare(
        on lease: TransferDriverLease?,
        readOnly: Bool,
        report: @Sendable (TransferProgress) -> Void
    ) async throws -> (any PluginExportDataSource, [PluginExportTable], Int?) {
        switch request.source {
        case .objects(let objects):
            guard let lease else { throw CancellationError() }
            let catalog = try await ExportObjectListing.catalog(
                on: lease.driver, databaseType: request.databaseType, database: request.database, schema: request.schema
            )
            let source = MobileExportDataSource(
                catalog: catalog,
                driver: lease.driver,
                databaseType: request.databaseType,
                readOnly: readOnly,
                skipsSnapshotStatements: lease.isSessionDriver
            )
            var counting = TransferProgress(stage: .counting)
            counting.objectCount = objects.count
            report(counting)
            let total = await countRows(of: objects, in: source, driver: lease.driver, readOnly: readOnly)
            return (source, objects, total)
        case .query(let select):
            guard let lease else { throw CancellationError() }
            let source = MobileQueryExportDataSource(
                query: select.statement(on: lease.driver),
                driver: lease.driver,
                databaseType: request.databaseType,
                readOnly: readOnly,
                skipsSnapshotStatements: lease.isSessionDriver
            )
            return (source, [queryTable], nil)
        case .rerun(let query):
            guard let lease else { throw CancellationError() }
            guard lease.driver.enforcesReadOnlyMode else {
                throw MobileTransferRefusal(reason: String(
                    localized: "This connection cannot run the query again read-only, so it was not run. Export the rows shown instead."
                ))
            }
            let source = MobileQueryExportDataSource(
                query: query,
                driver: lease.driver,
                databaseType: request.databaseType,
                readOnly: true,
                skipsSnapshotStatements: lease.isSessionDriver
            )
            return (source, [queryTable], nil)
        case .rows(let rows):
            let source = MobileRowsExportDataSource(
                rows: rows, databaseType: request.databaseType, sessionDriver: request.sessionDriver
            )
            return (source, [queryTable], rows.count)
        }
    }

    // A result has no structure behind it, so a query export asks only for data, as macOS `QueryExportOptions` does.
    private var queryTable: PluginExportTable {
        PluginExportTable(
            name: request.fileName,
            databaseName: "",
            tableType: "query",
            optionValues: QueryExportOptions.dataOnly(
                columns: type(of: plugin).perTableOptionColumns,
                defaults: plugin.defaultTableOptionValues()
            ),
            schema: nil,
            kind: .table
        )
    }

    private func write(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        to destination: URL,
        total: Int?,
        report: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> (format: ExportFormatResult, rows: Int) {
        let nsProgress = SharedProgress(Progress(totalUnitCount: Int64(total ?? 0)))
        let progress = PluginExportProgress(progress: nsProgress.progress)
        let stopped = lock.withLock { () -> Bool in
            pluginProgress = progress
            return stopRequested
        }
        if stopped { progress.cancel() }
        defer { lock.withLock { pluginProgress = nil } }

        let objectCount = tables.count
        let read: @Sendable () -> TransferProgress = {
            var running = TransferProgress(stage: .running)
            running.completedUnits = progress.processedRows
            running.totalUnits = total
            running.objectCount = objectCount
            running.objectIndex = progress.currentTableIndex
            running.objectName = nsProgress.description
            running.status = nsProgress.status
            return running
        }
        let poller = TransferProgressPoller()
        poller.start(read: read, report: report)
        do {
            let result = try await plugin.export(
                tables: tables, dataSource: dataSource, destination: destination, progress: progress
            )
            var finished = read()
            finished.stage = .finishing
            poller.stop(final: finished, report: report)
            return (result, progress.processedRows)
        } catch {
            poller.stop(final: nil, report: report)
            throw error
        }
    }

    // A total the bar can show: COUNT(*) where the engine speaks SQL, the catalog's estimate elsewhere. An object that
    // cannot be counted leaves the total out rather than showing a short one.
    private func countRows(
        of objects: [PluginExportTable],
        in source: MobileExportDataSource,
        driver: any DatabaseDriver,
        readOnly: Bool
    ) async -> Int? {
        let counted = objects.filter { $0.kind.carriesRows && plugin.readsRows(optionValues: $0.optionValues, kind: $0.kind) }
        guard !counted.isEmpty else { return nil }
        var total = 0
        for object in counted {
            guard !isCancelled else { return nil }
            do {
                let count: Int?
                if let query = source.rowCountQuery(for: object) {
                    count = try await MobileExportStreams.count(query, on: driver, readOnly: readOnly)
                } else {
                    count = try await source.fetchApproximateRowCount(table: object.name, databaseName: object.databaseName)
                }
                guard let count else { return nil }
                total = total.addingReportingOverflow(count).overflow ? .max : total + count
            } catch {
                Self.logger.warning("Could not count the rows to export: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
                return nil
            }
        }
        return total
    }
}

// The first of several ways a wait can end wins; the others find it taken. `await task.value` alone cannot give up on
// a task that never finishes.
nonisolated final class FirstResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, any Error>?
    private var waiters: [CheckedContinuation<Value, any Error>] = []

    @discardableResult
    func settle(_ result: Result<Value, any Error>) -> Bool {
        let waiting = lock.withLock { () -> [CheckedContinuation<Value, any Error>]? in
            guard self.result == nil else { return nil }
            self.result = result
            defer { waiters = [] }
            return waiters
        }
        guard let waiting else { return false }
        for waiter in waiting {
            waiter.resume(with: result)
        }
        return true
    }

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let settled = lock.withLock { () -> Result<Value, any Error>? in
                if let result { return result }
                waiters.append(continuation)
                return nil
            }
            if let settled { continuation.resume(with: settled) }
        }
    }
}
