import Foundation

// Set by Stop while a statement's request runs apart from the caller's task.
public final class BigQueryStopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    public init() {}

    public var isStopped: Bool {
        lock.withLock { stopped }
    }

    public func stop() {
        lock.withLock { stopped = true }
    }
}

public enum BigQueryRequestLoop {
    public struct Answer: Sendable {
        public let status: Int
        public let data: Data

        public init(status: Int, data: Data) {
            self.status = status
            self.data = data
        }
    }

    public static let rateLimitRetries = 3
    private static let unauthorizedStatus = 401
    private static let rateLimitedStatus = 429

    // Refreshes the token once on 401 and waits out a few 429s. Nil when Stop came before a send: a request the server
    // turned away ran nothing, so no retry may start the statement after Stop. Stop is read again once the token is
    // in hand, because fetching one can take a round trip of its own.
    public static func run<Token>(
        isStopped: () -> Bool,
        authorize: () async throws -> Token,
        send: (Token) async throws -> Answer,
        refreshToken: () async -> Void,
        backoff: (Int) async throws -> Void
    ) async throws -> Answer? {
        var rateLimitAttempt = 0
        var refreshedToken = false
        while true {
            guard !isStopped() else { return nil }
            let token = try await authorize()
            guard !isStopped() else { return nil }
            let answer = try await send(token)
            if answer.status == unauthorizedStatus, !refreshedToken {
                refreshedToken = true
                await refreshToken()
            } else if answer.status == rateLimitedStatus, rateLimitAttempt < rateLimitRetries {
                rateLimitAttempt += 1
                try await backoff(rateLimitAttempt)
            } else {
                return answer
            }
        }
    }
}

public enum BigQueryStoppableRequest {
    // Waits for a request that runs apart from the caller, since cancelling it on the wire would lose the job reference
    // its answer carries. Stop raises `stop` and lets the caller go once the answer is in or `grace` has passed,
    // whichever is first. An answer the caller did not take goes to `afterStop`, so a statement still running can be
    // cancelled once its reference arrives. A request still unanswered `abandonAfter` past Stop is cancelled, so no
    // stopped request outlives that.
    public static func value<Answer: Sendable>(
        of request: Task<Answer, any Error>,
        stop: BigQueryStopSignal,
        grace: Duration,
        abandonAfter: Duration,
        clock: any Clock<Duration> = ContinuousClock(),
        afterStop: @escaping @Sendable (Answer) async -> Void
    ) async throws -> Answer {
        let handoff = Handoff<Answer>()
        Task {
            let result = await request.result
            let delivered = !stop.isStopped && handoff.settle(result)
            guard !delivered else { return }
            _ = handoff.settle(.failure(CancellationError()))
            if case .success(let answer) = result {
                await afterStop(answer)
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                handoff.install(continuation)
            }
        } onCancel: {
            stop.stop()
            Task {
                try? await clock.sleep(for: grace)
                _ = handoff.settle(.failure(CancellationError()))
            }
            Task {
                try? await clock.sleep(for: abandonAfter)
                request.cancel()
            }
        }
    }

    private final class Handoff<Answer: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Answer, any Error>?
        private var outcome: Result<Answer, any Error>?
        private var settled = false

        func install(_ waiting: CheckedContinuation<Answer, any Error>) {
            let ready: Result<Answer, any Error>? = lock.withLock {
                guard let outcome else {
                    continuation = waiting
                    return nil
                }
                return outcome
            }
            if let ready { waiting.resume(with: ready) }
        }

        // True when this outcome is the one the caller gets.
        func settle(_ result: Result<Answer, any Error>) -> Bool {
            let (first, waiting) = lock.withLock { () -> (Bool, CheckedContinuation<Answer, any Error>?) in
                guard !settled else { return (false, nil) }
                settled = true
                let waiting = continuation
                continuation = nil
                if waiting == nil { outcome = result }
                return (true, waiting)
            }
            waiting?.resume(with: result)
            return first
        }
    }
}
