import Foundation

public enum GoogleAccessTokenWait {
    // A cancelled caller stops waiting; the fetch, which other callers may share, runs on to its end.
    public static func token(from provider: any GoogleAccessTokenProviding) async throws -> String {
        let wait = TokenWait(provider: provider)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { caller in
                wait.start(caller: caller)
            }
        } onCancel: {
            wait.cancel()
        }
    }
}

private final class TokenWait: @unchecked Sendable {
    typealias Caller = CheckedContinuation<String, any Error>

    private enum Stage {
        case notStarted
        case cancelledBeforeStart
        case waiting(Caller)
        case finished
    }

    private let provider: any GoogleAccessTokenProviding
    private let lock = NSLock()
    private var stage = Stage.notStarted

    init(provider: any GoogleAccessTokenProviding) {
        self.provider = provider
    }

    func start(caller waiting: Caller) {
        let launches: Bool = lock.withLock {
            switch stage {
            case .notStarted:
                stage = .waiting(waiting)
                return true
            case .cancelledBeforeStart:
                stage = .finished
                return false
            case .waiting, .finished:
                return false
            }
        }
        guard launches else {
            waiting.resume(throwing: CancellationError())
            return
        }
        Task { [provider] in
            let result: Result<String, any Error>
            do {
                result = .success(try await provider.accessToken())
            } catch {
                result = .failure(error)
            }
            self.finish(with: result)
        }
    }

    func cancel() {
        let waiting: Caller? = lock.withLock {
            switch stage {
            case .notStarted:
                stage = .cancelledBeforeStart
                return nil
            case .waiting(let caller):
                stage = .finished
                return caller
            case .cancelledBeforeStart, .finished:
                return nil
            }
        }
        waiting?.resume(throwing: CancellationError())
    }

    private func finish(with result: Result<String, any Error>) {
        let waiting: Caller? = lock.withLock {
            guard case .waiting(let caller) = stage else { return nil }
            stage = .finished
            return caller
        }
        waiting?.resume(with: result)
    }
}
