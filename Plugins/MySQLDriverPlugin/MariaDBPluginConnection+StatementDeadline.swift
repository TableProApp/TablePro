//
//  MariaDBPluginConnection+StatementDeadline.swift
//  MySQLDriverPlugin
//
//  Stopping a statement on a server that has no statement timeout of its own.
//

import CMariaDB
import Foundation
import OSLog

private let deadlineLogger = Logger(subsystem: "com.TablePro", category: "MariaDBStatementDeadline")

internal extension MariaDBPluginConnection {
    /// Wraps one statement on the primary handle. Runs on `queue`, which is serial, so the kill the
    /// deadline sends and the statement it names cannot outlive each other.
    ///
    /// Every statement this connection sends goes through here, the buffered read, the prepared
    /// statement and the export stream alike, which is why the latched-kill check belongs here and
    /// not beside one of them. Hooking only the two buffered paths left an export right after a Stop
    /// collecting the kill instead.
    func runStatement<T>(_ sql: String, _ body: () throws -> T) throws -> T {
        absorbLatchedKillIfNeeded()
        /// A stop's `KILL <id>` can land between the driver handing out this connection and here.
        /// The cancel queue is drained by now, so the flag is current and the statement is not sent.
        if sessionEndedByKill { throw MariaDBPluginError.notSentAfterSessionEnded }
        return try deadlineRunner(threadId: currentThreadId, target: killTarget).run(sql, body: body)
    }

    private func deadlineRunner(threadId: UInt, target: MySQLKillTarget) -> MySQLStatementDeadlineRunner {
        MySQLStatementDeadlineRunner(
            deadline: statementDeadline,
            flavor: flavor,
            killEndsSession: target.endsSession,
            socketTimeoutSeconds: socketTimeoutSeconds,
            watch: statementWatch,
            now: { ContinuousClock.now },
            schedule: { [deadlineQueue] duration, action in
                let item = DispatchWorkItem(block: action)
                let milliseconds = max(Int(duration / .milliseconds(1)), 0)
                deadlineQueue.asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: item)
                return { item.cancel() }
            },
            expire: { [weak self] token in self?.expireStatement(token: token, threadId: threadId, target: target) },
            flushInterrupt: { [weak self] in self?.consumePendingInterrupt() },
            killOrphan: { [weak self] in self?.killOrphanedStatement(threadId: threadId) },
            failureDetail: { error in
                guard let failure = error as? MariaDBPluginError else { return nil }
                return MySQLStatementFailure(code: failure.code, message: failure.message)
            },
            deadlineExceeded: { MariaDBPluginError.queryTimeoutExceeded(seconds: $0) },
            markOutlasted: { error in
                guard var failure = error as? MariaDBPluginError else { return error }
                failure.outlastedSocketTimeout = true
                return failure
            }
        )
    }

    /// The kill connection is opened before the watch's lock is taken, because taking it is what
    /// holds the statement's own completion, and opening a connection across the internet costs
    /// 800-1900ms. Inside the lock the watch re-checks that the statement is still running, so a
    /// statement that finished while the connection was opening is never killed.
    ///
    /// A kill that ends the session waits for the driver's word that the session holds nothing.
    private func expireStatement(token: UInt64, threadId: UInt, target: MySQLKillTarget) {
        guard statementWatch.isRunning(token) else { return }
        guard let statement = target.statement(threadId: threadId) else { return }
        if target.endsSession, !deadlineMayEndSession() {
            deadlineLogger.info("Query timeout left the statement running: stopping it would end a session that holds state")
            return
        }
        guard let killConn = openKillConnection() else {
            deadlineLogger.warning("Query timeout could not open a connection to stop the statement")
            return
        }
        defer { mysql_close(killConn) }
        statementWatch.expire(token) {
            guard sendKill(statement, on: killConn) else { return false }
            if target.endsSession { recordSessionEndedByKill(approved: true) }
            return true
        }
    }
}
