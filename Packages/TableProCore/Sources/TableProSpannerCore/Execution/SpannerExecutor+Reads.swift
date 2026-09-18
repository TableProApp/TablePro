import Foundation

extension SpannerExecutor {
    func queryStream(_ statement: SpannerPreparedStatement) -> AsyncThrowingStream<SpannerStreamOutput, Error> {
        makeStream { continuation in
            if await self.transactions.isIdle {
                try await self.streamOnReadSession(statement, into: continuation)
                return
            }
            try await self.transactions.queue.run {
                switch try await self.transactions.claim() {
                case .idle:
                    try await self.streamOnReadSession(statement, into: continuation)
                case .open(let context):
                    try await self.streamInTransaction(statement, context: context, into: continuation)
                }
            }
        }
    }

    func readStream(_ statement: SpannerPreparedStatement) -> AsyncThrowingStream<SpannerStreamOutput, Error> {
        makeStream { continuation in
            try await self.streamOnReadSession(statement, into: continuation)
        }
    }

    func queryParameterTypes(for statement: SpannerPreparedStatement) async throws -> (types: [SpannerType], cached: Bool) {
        if let declared = statement.declaredTypes {
            return (declared, false)
        }
        if let cached = await typeCache.types(for: statement.sql) {
            return (cached, true)
        }
        let request = SpannerExecuteSqlRequest(sql: statement.sql, transaction: .singleUseStrongReadOnly, queryMode: .plan)
        let plan = try await onReadSession { session in
            try await self.client.executeSql(session: session, request)
        }
        let types = try SpannerParameterTypeCache.orderedTypes(
            from: plan.metadata?.undeclaredParameters ?? [],
            count: statement.parameters.count
        )
        await typeCache.store(types, for: statement.sql)
        return (types, false)
    }

    private func streamOnReadSession(
        _ statement: SpannerPreparedStatement,
        into continuation: AsyncThrowingStream<SpannerStreamOutput, Error>.Continuation
    ) async throws {
        let resolved = try await queryParameterTypes(for: statement)
        var progress = SpannerStreamProgress()
        do {
            try await streamReadAttempt(statement, types: resolved.types, progress: &progress, into: continuation)
        } catch let error as SpannerAPIError where progress.isPristine && resolved.cached && error.isInvalidArgument {
            await typeCache.evict(statement.sql)
            let rediscovered = try await queryParameterTypes(for: statement)
            try await streamReadAttempt(statement, types: rediscovered.types, progress: &progress, into: continuation)
        }
    }

    private func streamReadAttempt(
        _ statement: SpannerPreparedStatement,
        types: [SpannerType],
        progress: inout SpannerStreamProgress,
        into continuation: AsyncThrowingStream<SpannerStreamOutput, Error>.Continuation
    ) async throws {
        let request = try executeRequest(statement, types: types, transaction: .singleUseStrongReadOnly, seqno: nil)
        let session = try await sessions.readSessionName()
        do {
            try await forward(try await client.executeStreamingSql(session: session, request), progress: &progress, into: continuation)
        } catch let error as SpannerAPIError where error.isSessionNotFound && progress.isPristine {
            await sessions.discardReadSession(session)
            let fresh = try await sessions.readSessionName()
            try await forward(try await client.executeStreamingSql(session: fresh, request), progress: &progress, into: continuation)
        }
    }

    private func streamInTransaction(
        _ statement: SpannerPreparedStatement,
        context: SpannerTransactionContext,
        into continuation: AsyncThrowingStream<SpannerStreamOutput, Error>.Continuation
    ) async throws {
        let types = try await queryParameterTypes(for: statement).types
        let request = try executeRequest(statement, types: types, transaction: .id(context.transactionId), seqno: nil)
        var progress = SpannerStreamProgress()
        do {
            let events = try await client.executeStreamingSql(session: context.session, request)
            try await forward(events, progress: &progress, into: continuation)
        } catch let error as SpannerAPIError where error.isAborted || error.isSessionNotFound {
            await transactions.markAborted(context)
            throw error
        }
    }

    private func forward(
        _ events: AsyncThrowingStream<SpannerStreamEvent, Error>,
        progress: inout SpannerStreamProgress,
        into continuation: AsyncThrowingStream<SpannerStreamOutput, Error>.Continuation
    ) async throws {
        for try await event in events {
            switch event {
            case .metadata(let metadata):
                progress.fields = metadata.fields
                progress.headerSent = true
                continuation.yield(.header(metadata.fields))
            case .rows(let rows):
                progress.rowsSent = true
                continuation.yield(.rows(SpannerValueDecoder.rows(rows, fields: progress.fields)))
            case .stats:
                continue
            }
        }
        if !progress.headerSent {
            progress.headerSent = true
            continuation.yield(.header([]))
        }
    }

    private func makeStream(
        _ produce: @escaping @Sendable (AsyncThrowingStream<SpannerStreamOutput, Error>.Continuation) async throws -> Void
    ) -> AsyncThrowingStream<SpannerStreamOutput, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try self.ensureOpen()
                    try await produce(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

internal struct SpannerStreamProgress: Sendable {
    var fields: [SpannerField] = []
    var headerSent = false
    var rowsSent = false

    var isPristine: Bool {
        !headerSent && !rowsSent
    }
}
