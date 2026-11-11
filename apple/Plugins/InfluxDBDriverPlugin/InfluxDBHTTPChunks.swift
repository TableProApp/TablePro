import Foundation
import TableProInfluxDBCore

// The body of a streamed read as the socket delivers it. It is the task's delegate, not the session's, so the
// session's own delegate still answers the server trust challenge. The transfer is suspended as each chunk is handed
// over and resumed once the decoder is done with it, so undecoded body never piles up.
final class InfluxDBHTTPChunks: PluginRedirectRefusingDelegate, URLSessionDataDelegate, @unchecked Sendable {
    // An error body is a message for the user; InfluxDB's run to a few hundred bytes.
    private static let errorBodyByteCap = 65_536

    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var isTransferSuspended = false
    private var refusal: Error?
    private var failedResponse: HTTPURLResponse?
    private var failureBody = Data()

    // Takes over the task's delegate; the caller resumes it.
    init(task: URLSessionDataTask) {
        (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        self.task = task
        super.init()
        task.delegate = self
        continuation.onTermination = { _ in task.cancel() }
    }

    // The task is torn down on every way out. A reader that throws leaves it suspended mid-body with nothing left to
    // resume it, which would hold the connection open until the driver disconnects.
    func forEachChunk(_ body: (Data) async throws -> Void) async throws {
        defer { endTransfer() }
        for try await chunk in stream {
            try await body(chunk)
            resumeTransfer()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            lock.withLock { refusal = InfluxError.malformedResponse("Not an HTTP response") }
            completionHandler(.cancel)
            return
        }
        if !(200 ..< 300).contains(http.statusCode) {
            lock.withLock { failedResponse = http }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let isFailure = lock.withLock { () -> Bool in
            guard failedResponse != nil else { return false }
            if failureBody.count < Self.errorBodyByteCap {
                failureBody.append(data.prefix(Self.errorBodyByteCap - failureBody.count))
            }
            return true
        }
        guard !isFailure else { return }

        // Suspended under the lock and before the reader sees the chunk, so the flag and the task never disagree.
        lock.withLock {
            guard !isTransferSuspended else { return }
            isTransferSuspended = true
            dataTask.suspend()
        }
        continuation.yield(data)
    }

    // The same error `send` gives for the same response, so a refused statement reads alike on both paths.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let failure = lock.withLock { () -> Error? in
            if let refusal { return refusal }
            if let error { return error }
            guard let response = failedResponse else { return nil }
            return InfluxDBResponse(statusCode: response.statusCode, headers: response.allHeaderFields, data: failureBody)
                .error
        }
        guard let failure else {
            continuation.finish()
            return
        }
        continuation.finish(throwing: failure)
    }

    private func resumeTransfer() {
        lock.withLock {
            guard isTransferSuspended else { return }
            isTransferSuspended = false
            task?.resume()
        }
    }

    private func endTransfer() {
        let outstanding = lock.withLock { () -> URLSessionDataTask? in
            let current = task
            task = nil
            isTransferSuspended = false
            return current
        }
        outstanding?.cancel()
        continuation.finish()
    }
}
