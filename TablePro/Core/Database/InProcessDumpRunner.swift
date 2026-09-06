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

    func cancel() {
        stateLock.lock()
        wasCancelled = true
        let driver = runningDriver
        stateLock.unlock()
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
        let statements = job.statements
        let cleanup = job.cleanupStatements
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
                do {
                    for statement in statements {
                        _ = try await driver.execute(query: statement)
                    }
                } catch {
                    /// Best effort and deliberately ignored. DuckDB aborts the whole transaction on
                    /// a failed `COPY FROM DATABASE`, so the `DETACH` that would tidy up fails too,
                    /// and the caller has the real error to report instead of this one. The alias is
                    /// unique per run, so a leaked attachment blocks nothing.
                    for statement in cleanup {
                        _ = try? await driver.execute(query: statement)
                    }
                    throw error
                }
            }
            finish(NativeDumpRunResult(exitCode: 0, stderr: "", wasCancelled: readCancelled()))
        } catch {
            let cancelled = readCancelled()
            Self.logger.error("in-engine dump failed: \(error.localizedDescription, privacy: .public)")
            finish(
                NativeDumpRunResult(
                    exitCode: cancelled ? 130 : 1,
                    stderr: cancelled ? "" : error.localizedDescription,
                    wasCancelled: cancelled
                )
            )
        }
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
