import Foundation

// Reads a response body into memory, at most `limit` bytes of it. Past that the transfer is cancelled and the read
// throws, however the server frames the body.
public enum BoundedHTTPRead {
    public struct BodyTooLarge: Error, Equatable {
        public let limit: Int

        public init(limit: Int) {
            self.limit = limit
        }
    }

    public static func data(
        for request: URLRequest,
        session: URLSession,
        limit: Int
    ) async throws -> (Data, URLResponse) {
        let transfer = BoundedTransfer(limit: limit)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transfer.start(request, on: session, continuation: continuation)
            }
        } onCancel: {
            transfer.cancel()
        }
    }
}

// A per-task delegate, so the session keeps its own delegate for redirects and trust.
private final class BoundedTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var body = Data()
    private var continuation: CheckedContinuation<(Data, URLResponse), any Error>?
    private var task: URLSessionDataTask?
    private var isCancelled = false

    init(limit: Int) {
        self.limit = max(limit, 0)
    }

    func start(
        _ request: URLRequest,
        on session: URLSession,
        continuation waiting: CheckedContinuation<(Data, URLResponse), any Error>
    ) {
        let dataTask = session.dataTask(with: request)
        dataTask.delegate = self
        let proceeds = lock.withLock { () -> Bool in
            guard !isCancelled else { return false }
            continuation = waiting
            task = dataTask
            return true
        }
        guard proceeds else {
            waiting.resume(throwing: URLError(.cancelled))
            return
        }
        dataTask.resume()
    }

    func cancel() {
        let running = lock.withLock { () -> URLSessionDataTask? in
            isCancelled = true
            return task
        }
        running?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overLimit = lock.withLock { () -> Bool in
            guard continuation != nil else { return false }
            guard data.count <= limit - body.count else { return true }
            body.append(data)
            return false
        }
        guard overLimit else { return }
        finish(.failure(BoundedHTTPRead.BodyTooLarge(limit: limit)))
        dataTask.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            finish(.failure(error))
        } else if let response = task.response {
            finish(.success((lock.withLock { body }, response)))
        } else {
            finish(.failure(URLError(.badServerResponse)))
        }
    }

    private func finish(_ result: Result<(Data, URLResponse), any Error>) {
        let waiting = lock.withLock { () -> CheckedContinuation<(Data, URLResponse), any Error>? in
            defer {
                continuation = nil
                body = Data()
            }
            return continuation
        }
        waiting?.resume(with: result)
    }
}
