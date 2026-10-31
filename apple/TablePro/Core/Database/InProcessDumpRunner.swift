//
//  InProcessDumpRunner.swift
//  TablePro
//

import Foundation
import os

/// Runs a dump the engine performs for itself, over the connection the app already holds.
///
/// DuckDB's backup is `ATTACH` plus `COPY FROM DATABASE`, statements its own in-process engine
/// executes. There is no binary to find, no password to hand over and nothing to reap, so none of
/// `ProcessNativeDumpRunner` applies, but everything above the runner does: the same progress,
/// cancel confirmation and result sheet.
///
/// It takes the session driver through `withScopedDriver`, never `driver(for:)` directly, so the
/// statements serialize on `sessionDriverGate` against whatever a query tab is doing. The lease is
/// `.protectedWrite`, which keeps a Stop pressed on an unrelated query tab from aborting a backup
/// mid-write; cancellation reaches this run through the driver handle captured below instead.
final class InProcessDumpRunner: NativeDumpRunner, @unchecked Sendable {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "InProcessDump")

    private let job: NativeDumpStatementJob
    private let stateLock = NSLock()
    private var wasCancelled = false
    private var runningDriver: DatabaseDriver?
    private var terminationResult: NativeDumpRunResult?
    private var continuation: CheckedContinuation<NativeDumpRunResult, Never>?
    private var task: Task<Void, Never>?

    init(job: NativeDumpStatementJob) {
        self.job = job
    }

    func start() throws {
        task = Task { [weak self] in
            guard let self else { return }
            await self.execute()
        }
    }

    // The task's cancellation reaches the isolated import, which `cancelQuery` on the session driver cannot.
    func cancel() {
        stateLock.lock()
        wasCancelled = true
        let driver = runningDriver
        stateLock.unlock()
        task?.cancel()
        try? driver?.cancelQuery()
    }

    var result: NativeDumpRunResult {
        get async {
            await withCheckedContinuation { continuation in
                stateLock.lock()
                if let cached = terminationResult {
                    stateLock.unlock()
                    continuation.resume(returning: cached)
                    return
                }
                self.continuation = continuation
                stateLock.unlock()
            }
        }
    }

    private func execute() async {
        let result = await run()
        if let isolated = job.isolatedImport {
            try? FileManager.default.removeItem(at: isolated.directory)
        }
        finish(result)
    }

    private func run() async -> NativeDumpRunResult {
        let job = self.job
        let adopt: @Sendable (DatabaseDriver?) -> Void = { [weak self] driver in
            guard let self else { return }
            self.stateLock.lock()
            self.runningDriver = driver
            self.stateLock.unlock()
        }

        do {
            try await DatabaseManager.shared.withScopedDriver(
                scope: job.scope,
                route: .sessionDriver,
                cancellation: .protectedWrite
            ) { driver in
                adopt(driver)
                defer { adopt(nil) }
                if let isolated = job.isolatedImport {
                    do {
                        try await driver.importExportedDatabase(from: isolated.archive, into: isolated.file)
                    } catch {
                        throw IsolatedImportFailure(underlying: error)
                    }
                }
                do {
                    for statement in job.statements {
                        try Task.checkCancellation()
                        _ = try await driver.execute(query: statement)
                    }
                } catch {
                    // Ignored: the DETACH can fail in the transaction the COPY aborted, and the alias is unique per run.
                    for statement in job.cleanupStatements {
                        _ = try? await driver.execute(query: statement)
                    }
                    throw error
                }
            }
            return NativeDumpRunResult(exitCode: 0, stderr: "", wasCancelled: readCancelled())
        } catch {
            let cancelled = readCancelled()
            let isolated = error as? IsolatedImportFailure
            Self.logger.error("in-engine dump failed: \((isolated?.underlying ?? error).publicLogShape, privacy: .public)")
            return NativeDumpRunResult(
                exitCode: cancelled ? 130 : 1,
                stderr: cancelled ? "" : Self.message(for: error),
                wasCancelled: cancelled,
                targetUntouched: isolated != nil
            )
        }
    }

    private static func message(for error: any Error) -> String {
        guard let isolated = error as? IsolatedImportFailure else { return error.localizedDescription }
        return String(
            format: String(localized: "The backup could not be imported, so this database was not changed. %@"),
            isolated.underlying.localizedDescription
        )
    }

    private func readCancelled() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return wasCancelled
    }

    private func finish(_ result: NativeDumpRunResult) {
        stateLock.lock()
        guard terminationResult == nil else {
            stateLock.unlock()
            return
        }
        terminationResult = result
        runningDriver = nil
        let pending = continuation
        continuation = nil
        stateLock.unlock()
        pending?.resume(returning: result)
    }
}

private struct IsolatedImportFailure: Error {
    let underlying: any Error
}
