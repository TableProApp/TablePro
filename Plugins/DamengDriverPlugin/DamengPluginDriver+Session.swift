import Foundation
import TableProPluginKit

/// Whether a statement may be sent again after the connection was rebuilt under it.
///
/// A DM8 connection cannot survive a stop or a timeout, so recovering means running the
/// statement on a new one. That is only safe when running it twice is the same as running it
/// once: the server may already have applied the first attempt before the reply was abandoned.
enum DamengReplayPolicy {
    /// Reads, and the driver's own session statements, which land the same way every time.
    ///
    /// The test is the leading keyword, so a read that writes through a function it calls, or
    /// one the caller appended a second statement to, is still sent twice. That is the same
    /// bound the shipped MySQL driver works to.
    case replayable
    /// Anything that can change data. A write is reported instead, because the abandoned
    /// attempt may have committed.
    case reportFailure
}

extension DamengPluginDriver {
    /// Runs a statement, and when the connection died under it, rebuilds the connection and
    /// runs it once more.
    ///
    /// This is the shape MySQL (`MySQLPluginDriver.executeWithReconnect`) and PostgreSQL
    /// (`LibPQDriverCore.executeWithReconnect`) already ship, and it is what the Dameng
    /// driver's own documentation has always claimed to do. A stop is never retried: the user
    /// asked for the statement to end.
    func executeWithReconnect(
        query: String,
        parameters: [PluginCellValue],
        rowCap: Int?,
        replay: DamengReplayPolicy,
        isRetry: Bool = false
    ) async throws -> PluginQueryResult {
        do {
            return try await executeOnce(query: query, parameters: parameters, rowCap: rowCap)
        } catch let error as DamengError where error.closedConnection && hasOpenTransaction {
            // Rebuilding here would put the rest of the transaction on a connection that never
            // saw its BEGIN, and the commit would then report success having written nothing.
            endTransaction()
            throw DamengError(message: String(localized: """
                The Dameng connection was lost, so the open transaction was rolled back. \
                Run its statements again.
                """))
        } catch let error as DamengError where !isRetry
            && error.closedConnection
            && replay == .replayable
            && hasConnectedBefore
        {
            try await reconnect()
            return try await executeWithReconnect(
                query: query,
                parameters: parameters,
                rowCap: rowCap,
                replay: replay,
                isRetry: true
            )
        }
    }

    /// Rebuilds the connection once, however many statements found it dead.
    ///
    /// Each caller starting its own rebuild would retire the connection the previous one had
    /// just adopted, so the winner's own follow-up statements would fail on a handle replaced
    /// under them. Concurrent callers await the same task instead, which is the shape
    /// `SQLSchemaProvider` uses for the same reason.
    func reconnect(restoringSchema schema: String? = nil) async throws {
        let target = schema ?? activeSchema
        let rebuild: (task: Task<Void, any Error>, isOwn: Bool) = sessionLock.withLock {
            if let inFlight = reconnectInFlight { return (inFlight, false) }
            let task = Task { [weak self] in
                guard let self else { return }
                defer { self.sessionLock.withLock { self.reconnectInFlight = nil } }
                try await self.rebuildSession(restoringSchema: target)
            }
            reconnectInFlight = task
            return (task, true)
        }
        try await rebuild.task.value
        // A rebuild started by someone else restored the schema THEY asked for, so a caller
        // switching to a different one has to apply it itself or it would return success
        // having left the session resolving names in the old schema.
        guard !rebuild.isOwn, let target, !target.isEmpty, target != activeSchema else { return }
        try await applySchema(target)
    }

    /// Puts the session back where the statements expect it.
    ///
    /// Only the state this driver established itself is restored. The schema defaults to
    /// `activeSchema` rather than `config.database`, because the user may have switched since
    /// connecting and a statement that resolves unqualified names would otherwise land in the
    /// wrong schema.
    private func rebuildSession(restoringSchema schema: String?) async throws {
        try Task.checkCancellation()
        try await connection.connect(
            host: config.host,
            port: config.port,
            username: config.username,
            password: config.password
        )
        textEscaping = await detectTextEscaping()
        guard let schema, !schema.isEmpty else { return }
        try await applySchema(schema)
    }
}
