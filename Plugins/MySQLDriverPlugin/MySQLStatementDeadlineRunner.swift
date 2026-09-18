//
//  MySQLStatementDeadlineRunner.swift
//  MySQLDriverPlugin
//
//  The order a timed statement runs in. Every C call is injected, so TableProTests compiles it.
//

import Foundation

internal struct MySQLStatementFailure: Equatable {
    internal let code: UInt32
    internal let message: String
}

internal typealias MySQLDeadlineCancel = () -> Void

/// Runs one statement under a client-side deadline and classifies how it ended.
///
/// The connection supplies the parts that touch libmariadb: `expire` opens the second connection
/// and sends `KILL QUERY`, `flushInterrupt` runs a throwaway statement on the primary handle to
/// consume a kill the statement did not, and `killOrphan` stops a statement still running on the
/// server after the socket timeout gave up on it. Everything about the order they happen in lives
/// here, where a test can drive it.
internal struct MySQLStatementDeadlineRunner {
    internal let deadline: MySQLStatementDeadline?
    internal let flavor: MySQLServerFlavor
    internal let socketTimeoutSeconds: UInt32
    internal let watch: MySQLStatementWatch
    internal let now: () -> ContinuousClock.Instant
    internal let schedule: (Duration, @escaping () -> Void) -> MySQLDeadlineCancel
    internal let expire: (UInt64) -> Void
    internal let flushInterrupt: () -> Void
    internal let killOrphan: () -> Void
    internal let failureDetail: (any Error) -> MySQLStatementFailure?
    internal let deadlineExceeded: (Int) -> any Error
    internal let markOutlasted: (any Error) -> any Error

    internal func run<T>(_ sql: String, body: () throws -> T) throws -> T {
        guard let deadline, deadline.applies(to: sql) else { return try runUntimed(body) }

        let startedAt = now()
        let token = watch.begin()
        let cancelSchedule = schedule(.seconds(deadline.seconds)) { expire(token) }
        let outcome = Result(catching: body)
        cancelSchedule()
        let killWasSent = watch.end(token)

        switch outcome {
        case .success(let value):
            if killWasSent { flushInterrupt() }
            return value
        case .failure(let error):
            let cause = cause(of: error, waited: now() - startedAt, deadlineExpired: killWasSent)
            if cause == .deadlineExceeded { throw deadlineExceeded(deadline.seconds) }
            if killWasSent { flushInterrupt() }
            throw reported(error, cause: cause)
        }
    }

    /// A statement with no deadline still outlives the socket timeout, and on MySQL the engine's
    /// own timeout never covered it: measured on 5.7.44 with `max_execution_time = 2000`,
    /// `INSERT ... SELECT` ran for 170 seconds.
    private func runUntimed<T>(_ body: () throws -> T) throws -> T {
        let startedAt = now()
        do {
            return try body()
        } catch {
            let cause = cause(of: error, waited: now() - startedAt, deadlineExpired: false)
            throw reported(error, cause: cause)
        }
    }

    private func cause(
        of error: any Error,
        waited: Duration,
        deadlineExpired: Bool
    ) -> MySQLStatementFailureCause {
        guard let detail = failureDetail(error) else { return .server }
        return mysqlStatementFailureCause(
            errno: detail.code,
            message: detail.message,
            flavor: flavor,
            deadlineExpired: deadlineExpired,
            waited: waited,
            socketTimeoutSeconds: socketTimeoutSeconds
        )
    }

    private func reported(_ error: any Error, cause: MySQLStatementFailureCause) -> any Error {
        guard cause == .outlastedSocketTimeout else { return error }
        killOrphan()
        return markOutlasted(error)
    }
}
