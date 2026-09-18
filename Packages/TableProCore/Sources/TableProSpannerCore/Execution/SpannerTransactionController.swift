import Foundation

internal struct SpannerTransactionContext: Sendable, Equatable {
    let session: String
    let transactionId: String
}

internal enum SpannerTransactionOwner: Sendable, Equatable {
    case statement
    case host
}

internal actor SpannerTransactionController {
    enum State: Sendable, Equatable {
        case idle
        case open(SpannerTransactionContext, owner: SpannerTransactionOwner, lastSeqno: Int64)
        case aborted(SpannerTransactionContext, owner: SpannerTransactionOwner)
        case commitOutcomeUnknown(owner: SpannerTransactionOwner)
    }

    enum Claim: Sendable, Equatable {
        case idle
        case open(SpannerTransactionContext)
    }

    let queue = SpannerSerialQueue()
    private let client: SpannerRESTClient
    private let sessions: SpannerSessionManager
    private(set) var state: State = .idle

    init(client: SpannerRESTClient, sessions: SpannerSessionManager) {
        self.client = client
        self.sessions = sessions
    }

    var isIdle: Bool {
        state == .idle
    }

    func begin(owner: SpannerTransactionOwner) async throws {
        switch state {
        case .idle, .commitOutcomeUnknown:
            let context = try await beginOnFreshSession(retryingLostSession: true)
            state = .open(context, owner: owner, lastSeqno: 0)
        case .open, .aborted:
            throw SpannerExecutionError.transactionAlreadyOpen
        }
    }

    func commit(requestedBy requester: SpannerTransactionOwner) async throws {
        switch state {
        case .idle:
            throw SpannerExecutionError.noTransactionOpen
        case .commitOutcomeUnknown:
            state = .idle
            throw SpannerExecutionError.noTransactionOpen
        case .aborted(_, let owner):
            guard Self.may(requester, end: owner) else { throw SpannerExecutionError.noTransactionOpen }
            throw SpannerExecutionError.transactionAborted
        case .open(let context, let owner, _):
            guard Self.may(requester, end: owner) else { throw SpannerExecutionError.noTransactionOpen }
            state = .idle
            try await send(commitOf: context, owner: owner)
        }
    }

    func rollback(requestedBy requester: SpannerTransactionOwner) async throws {
        switch state {
        case .idle:
            return
        case .commitOutcomeUnknown(let owner):
            guard Self.may(requester, end: owner) else { return }
            state = .idle
            throw SpannerExecutionError.commitOutcomeUnknown
        case .open(let context, let owner, _), .aborted(let context, let owner):
            guard Self.may(requester, end: owner) else { return }
            state = .idle
            do {
                try await client.rollback(session: context.session, transactionId: context.transactionId)
                await sessions.releaseWriteSession(context.session)
            } catch {
                await settle(context.session, after: error)
            }
        }
    }

    func claim() throws -> Claim {
        switch state {
        case .idle:
            return .idle
        case .commitOutcomeUnknown:
            state = .idle
            return .idle
        case .aborted:
            throw SpannerExecutionError.transactionAborted
        case .open(let context, _, _):
            return .open(context)
        }
    }

    func nextSeqno(for context: SpannerTransactionContext) throws -> Int64 {
        guard case .open(let current, let owner, let lastSeqno) = state, current == context else {
            throw SpannerExecutionError.transactionAborted
        }
        let next = lastSeqno + 1
        state = .open(current, owner: owner, lastSeqno: next)
        return next
    }

    func markAborted(_ context: SpannerTransactionContext) {
        guard case .open(let current, let owner, _) = state, current == context else { return }
        state = .aborted(current, owner: owner)
    }

    func shutdown() async {
        switch state {
        case .open(let context, _, _), .aborted(let context, _):
            state = .idle
            try? await client.rollback(session: context.session, transactionId: context.transactionId)
            await sessions.releaseWriteSession(context.session)
        case .idle, .commitOutcomeUnknown:
            state = .idle
        }
    }

    private func send(commitOf context: SpannerTransactionContext, owner: SpannerTransactionOwner) async throws {
        let client = self.client
        let request = Task { try await client.commit(session: context.session, transactionId: context.transactionId) }
        do {
            try await request.value
            await sessions.releaseWriteSession(context.session)
        } catch {
            await settle(context.session, after: error)
            guard Self.outcomeIsUnknown(after: error) else { throw error }
            state = .commitOutcomeUnknown(owner: owner)
            throw SpannerExecutionError.commitOutcomeUnknown
        }
    }

    private func beginOnFreshSession(retryingLostSession: Bool) async throws -> SpannerTransactionContext {
        let session = try await sessions.leaseWriteSession()
        do {
            let identifier = try await client.beginTransaction(session: session)
            return SpannerTransactionContext(session: session, transactionId: identifier)
        } catch let error as SpannerAPIError where error.isSessionNotFound && retryingLostSession {
            await sessions.discardWriteSession(session)
            return try await beginOnFreshSession(retryingLostSession: false)
        } catch {
            await settle(session, after: error)
            throw error
        }
    }

    private func settle(_ session: String, after error: Error) async {
        if let apiError = error as? SpannerAPIError, apiError.isSessionNotFound {
            await sessions.discardWriteSession(session)
            return
        }
        await sessions.releaseWriteSession(session)
    }

    private static func may(_ requester: SpannerTransactionOwner, end owner: SpannerTransactionOwner) -> Bool {
        requester == .statement || requester == owner
    }

    static func outcomeIsUnknown(after error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        guard let transportError = error as? SpannerTransportError else { return false }
        switch transportError {
        case .timedOut, .network, .cancelled, .invalidResponse:
            return true
        case .closed:
            return false
        }
    }
}
