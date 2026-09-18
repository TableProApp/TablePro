import Foundation
import os
import TableProGoogleCloud

public final class SpannerExecutor: Sendable {
    static let logger = Logger(subsystem: "com.TablePro", category: "SpannerExecutor")

    public let dialect: SpannerDialect
    let client: SpannerRESTClient
    let sessions: SpannerSessionManager
    let transactions: SpannerTransactionController
    let typeCache = SpannerParameterTypeCache()
    let ddlDeadline: @Sendable () -> Duration?
    let abortedRetryDelays: [Duration]
    let schemaChangePollInterval: Duration
    private let closedState = OSAllocatedUnfairLock(initialState: false)

    public convenience init(
        client: SpannerRESTClient,
        dialect: SpannerDialect,
        ddlDeadline: @escaping @Sendable () -> Duration?
    ) {
        self.init(
            client: client,
            dialect: dialect,
            ddlDeadline: ddlDeadline,
            abortedRetryDelays: [.milliseconds(50), .milliseconds(100), .milliseconds(200), .milliseconds(400)],
            schemaChangePollInterval: .milliseconds(500)
        )
    }

    init(
        client: SpannerRESTClient,
        dialect: SpannerDialect,
        ddlDeadline: @escaping @Sendable () -> Duration?,
        abortedRetryDelays: [Duration],
        schemaChangePollInterval: Duration
    ) {
        self.client = client
        self.dialect = dialect
        self.ddlDeadline = ddlDeadline
        self.abortedRetryDelays = abortedRetryDelays
        self.schemaChangePollInterval = schemaChangePollInterval
        let sessions = SpannerSessionManager(client: client)
        self.sessions = sessions
        self.transactions = SpannerTransactionController(client: client, sessions: sessions)
    }

    public var hasOpenTransaction: Bool {
        get async { await !transactions.isIdle }
    }

    public func run(_ sql: String, hostParameters: [SpannerCell]?) async throws -> SpannerQueryOutcome {
        try ensureOpen()
        return try await run(prepare(sql, hostParameters: hostParameters))
    }

    public func run(_ statement: SpannerRenderedStatement) async throws -> SpannerQueryOutcome {
        try ensureOpen()
        let prepared = SpannerPreparedStatement(statement)
        let kind = SpannerStatementClassifier.classify(prepared.sql, dialect: dialect)
        switch kind {
        case .query:
            return try await collect(queryStream(prepared), kind: kind)
        case .dml:
            return try await executeDML(prepared)
        case .ddl:
            try await applySchemaChange(prepared.sql)
            return .empty(kind)
        case .begin:
            try await transactions.queue.run { try await self.transactions.begin(owner: .statement) }
            return .empty(kind)
        case .commit:
            try await transactions.queue.run { try await self.transactions.commit(requestedBy: .statement) }
            return .empty(kind)
        case .rollback:
            try await transactions.queue.run { try await self.transactions.rollback(requestedBy: .statement) }
            return .empty(kind)
        case .explain(let inner, let analyze):
            guard !analyze else { throw SpannerExecutionError.explainAnalyzeNotSupported }
            return try await explain(SpannerRenderedStatement(sql: inner))
        case .unsupportedTransactionControl:
            throw SpannerExecutionError.unsupportedTransactionControl
        }
    }

    public func stream(_ sql: String, hostParameters: [SpannerCell]?) -> AsyncThrowingStream<SpannerStreamOutput, Error> {
        do {
            try ensureOpen()
            return stream(try prepare(sql, hostParameters: hostParameters))
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    public func stream(_ statement: SpannerRenderedStatement) -> AsyncThrowingStream<SpannerStreamOutput, Error> {
        let prepared = SpannerPreparedStatement(statement)
        guard case .query = SpannerStatementClassifier.classify(prepared.sql, dialect: dialect) else {
            return outcomeStream(statement)
        }
        return queryStream(prepared)
    }

    public func read(_ statement: SpannerRenderedStatement) async throws -> [[SpannerCell]] {
        try ensureOpen()
        return try await collect(readStream(SpannerPreparedStatement(statement)), kind: .query).rows
    }

    public func beginTransaction() async throws {
        try ensureOpen()
        try await transactions.queue.run { try await self.transactions.begin(owner: .host) }
    }

    public func commitTransaction() async throws {
        try ensureOpen()
        try await transactions.queue.run { try await self.transactions.commit(requestedBy: .host) }
    }

    public func rollbackTransaction() async throws {
        try ensureOpen()
        try await transactions.queue.run { try await self.transactions.rollback(requestedBy: .host) }
    }

    public func ping() async throws {
        try ensureOpen()
        let request = SpannerExecuteSqlRequest(sql: "SELECT 1", transaction: .singleUseStrongReadOnly)
        _ = try await onReadSession { session in
            try await self.client.executeSql(session: session, request)
        }
    }

    public func databaseDDL() async throws -> [String] {
        try ensureOpen()
        return try await client.databaseDDL()
    }

    public func shutdown() async {
        let alreadyClosed = closedState.withLock { closed -> Bool in
            let previous = closed
            closed = true
            return previous
        }
        guard !alreadyClosed else { return }
        await transactions.shutdown()
        await sessions.shutdown()
        await client.close()
    }

    func ensureOpen() throws {
        if closedState.withLock({ $0 }) {
            throw SpannerExecutionError.closed
        }
    }

    func prepare(_ sql: String, hostParameters: [SpannerCell]?) throws -> SpannerRenderedStatement {
        guard let hostParameters else {
            return SpannerRenderedStatement(sql: sql, parameters: [], parameterTypes: [])
        }
        let dialect = self.dialect
        do {
            let rewritten = try SQLPlaceholderRewriter.rewrite(
                sql,
                lexicon: dialect.placeholderLexicon,
                expectedCount: hostParameters.count,
                placeholder: { dialect.placeholder($0) }
            )
            return SpannerRenderedStatement(
                sql: rewritten.sql,
                parameters: hostParameters,
                parameterTypes: hostParameters.isEmpty ? [] : nil
            )
        } catch SQLPlaceholderRewriteError.countMismatch(let found, let expected) {
            throw SpannerExecutionError.parameterCount(found: found, expected: expected)
        }
    }

    func collect(
        _ stream: AsyncThrowingStream<SpannerStreamOutput, Error>,
        kind: SpannerStatementKind
    ) async throws -> SpannerQueryOutcome {
        var fields: [SpannerField] = []
        var rows: [[SpannerCell]] = []
        for try await output in stream {
            switch output {
            case .header(let header):
                fields = header
            case .rows(let batch):
                rows.append(contentsOf: batch)
            }
        }
        try Task.checkCancellation()
        return SpannerQueryOutcome(fields: fields, rows: rows, rowsAffected: nil, kind: kind)
    }

    func onReadSession<T: Sendable>(_ body: @escaping @Sendable (String) async throws -> T) async throws -> T {
        let session = try await sessions.readSessionName()
        do {
            return try await body(session)
        } catch let error as SpannerAPIError where error.isSessionNotFound {
            await sessions.discardReadSession(session)
            return try await body(try await sessions.readSessionName())
        }
    }

    private func outcomeStream(_ statement: SpannerRenderedStatement) -> AsyncThrowingStream<SpannerStreamOutput, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let outcome = try await self.run(statement)
                    continuation.yield(.header(outcome.fields))
                    if !outcome.rows.isEmpty {
                        continuation.yield(.rows(outcome.rows))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

internal struct SpannerPreparedStatement: Sendable {
    let sql: String
    let parameters: [SpannerCell]
    let declaredTypes: [SpannerType]?

    init(_ statement: SpannerRenderedStatement) {
        self.sql = statement.sql
        self.parameters = statement.parameters
        self.declaredTypes = statement.parameters.isEmpty ? [] : statement.parameterTypes
    }

    var needsTypeDiscovery: Bool {
        declaredTypes == nil
    }
}
