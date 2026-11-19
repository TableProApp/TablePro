import Foundation

// Reads a response body into memory, at most `limit` bytes of it however the server frames the body.
public enum BoundedHTTPRead {
    public struct BodyTooLarge: Error, Equatable {
        public let limit: Int

        public init(limit: Int) {
            self.limit = limit
        }
    }

    // `onBodySent` runs once, when the whole request body has left the client.
    public static func data(
        for request: URLRequest,
        session: URLSession,
        limit: Int,
        onBodySent: @escaping @Sendable () -> Void = {}
    ) async throws -> (Data, URLResponse) {
        let transfer = BoundedTransfer(request: request, session: session, limit: limit, onBodySent: onBodySent)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { caller in
                transfer.start(caller: caller)
            }
        } onCancel: {
            transfer.cancel()
        }
    }
}

// A per-task delegate, so the session's own delegate still answers redirects and trust.
private final class BoundedTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Caller = CheckedContinuation<(Data, URLResponse), any Error>

    private enum Stage {
        case notStarted
        case cancelledBeforeStart
        case running
        case finished
    }

    private let request: URLRequest
    private let session: URLSession
    private let limit: Int
    private let onBodySent: @Sendable () -> Void
    private let lock = NSLock()
    private var stage = Stage.notStarted
    private var caller: Caller?
    private var task: URLSessionDataTask?
    private var body = Data()
    private var reportedBodySent = false

    init(request: URLRequest, session: URLSession, limit: Int, onBodySent: @escaping @Sendable () -> Void) {
        self.request = request
        self.session = session
        self.limit = max(limit, 0)
        self.onBodySent = onBodySent
    }

    func start(caller waiting: Caller) {
        let created: URLSessionDataTask? = lock.withLock {
            switch stage {
            case .notStarted:
                let dataTask = session.dataTask(with: request)
                dataTask.delegate = self
                stage = .running
                caller = waiting
                task = dataTask
                return dataTask
            case .cancelledBeforeStart:
                stage = .finished
                return nil
            case .running, .finished:
                return nil
            }
        }
        guard let created else {
            waiting.resume(throwing: URLError(.cancelled))
            return
        }
        created.resume()
    }

    func cancel() {
        let ended: (Caller, URLSessionDataTask)? = lock.withLock {
            switch stage {
            case .notStarted:
                stage = .cancelledBeforeStart
                return nil
            case .running:
                return finish()
            case .cancelledBeforeStart, .finished:
                return nil
            }
        }
        guard case let (waiting, dataTask)? = ended else { return }
        dataTask.cancel()
        waiting.resume(throwing: URLError(.cancelled))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let reports: Bool = lock.withLock {
            guard stage == .running, !reportedBodySent,
                  totalBytesExpectedToSend > 0, totalBytesSent >= totalBytesExpectedToSend
            else { return false }
            reportedBodySent = true
            return true
        }
        if reports {
            onBodySent()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let ended: (Caller, URLSessionDataTask)? = lock.withLock {
            guard stage == .running else { return nil }
            guard data.count <= limit - body.count else { return finish() }
            body.append(data)
            return nil
        }
        guard case let (waiting, runningTask)? = ended else { return }
        runningTask.cancel()
        waiting.resume(throwing: BoundedHTTPRead.BodyTooLarge(limit: limit))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let ended: (Caller, Result<(Data, URLResponse), any Error>)? = lock.withLock {
            guard stage == .running else { return nil }
            let received = body
            guard case let (waiting, _)? = finish() else { return nil }
            if let error {
                return (waiting, .failure(error))
            }
            guard let response = task.response else {
                return (waiting, .failure(URLError(.badServerResponse)))
            }
            return (waiting, .success((received, response)))
        }
        guard case let (waiting, result)? = ended else { return }
        waiting.resume(with: result)
    }

    // Runs under `lock` while running.
    private func finish() -> (Caller, URLSessionDataTask)? {
        stage = .finished
        body = Data()
        guard let waiting = caller, let running = task else { return nil }
        caller = nil
        task = nil
        return (waiting, running)
    }
}
