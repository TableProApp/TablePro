import Foundation
import TableProPluginKit

/// The response body of a streaming read, as the bytes the socket produced.
///
/// `URLSession.AsyncBytes.lines` hands back a UTF-8 decoded `String`, which replaces every byte a
/// `String` column holds that is not valid UTF-8 before anything can look at it, and iterating the
/// same sequence a byte at a time costs an async suspension per byte: measured on a million-row
/// read, 7.6s for `lines` and 44s for the bytes under it. A per-task delegate hands over the `Data`
/// untouched and about 85 KB at a time, and the same read then costs 0.18s. It is a *task* delegate
/// rather than a session one so the driver keeps its own session, and with it the
/// `ClickHouseTLSDelegate` that answers the server trust challenge.
///
/// One chunk is in flight at a time: the transfer is suspended as each chunk is handed over and
/// resumed once the reader has finished with it, so a slow writer downstream stops the download
/// rather than letting the rest of the result pile up in memory. That resume is why the body is
/// read through `forEachChunk` and not by iterating a sequence: a caller cannot forget it.
internal final class ClickHouseHTTPChunks: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// An error body is text the user reads, not a result, so it is held whole up to this and the
    /// rest dropped. ClickHouse exception text runs to a few kilobytes at most.
    private static let errorBodyByteCap = 65_536

    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var isTransferSuspended = false
    private var failureStatusCode: Int?
    private var failureBody = Data()

    internal init(session: URLSession, request: URLRequest) {
        (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        super.init()

        let dataTask = session.dataTask(with: request)
        dataTask.delegate = self
        lock.withLock { task = dataTask }
        continuation.onTermination = { _ in dataTask.cancel() }
        dataTask.resume()
    }

    /// The transfer is torn down on every way out, a thrown error and a cancellation included. A
    /// reader that walks away leaves the task suspended mid-body with nothing left to resume it, so
    /// without this the connection stays open until the driver disconnects.
    internal func forEachChunk(_ body: (Data) async throws -> Void) async throws {
        defer { endTransfer() }
        for try await chunk in stream {
            try await body(chunk)
            resumeTransfer()
        }
    }

    internal func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let statusCode = (response as? HTTPURLResponse)?.statusCode, statusCode >= 400 {
            lock.withLock { failureStatusCode = statusCode }
        }
        completionHandler(.allow)
    }

    internal func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let isFailure = lock.withLock { () -> Bool in
            guard failureStatusCode != nil else { return false }
            let room = Self.errorBodyByteCap - failureBody.count
            if room > 0 { failureBody.append(data.prefix(room)) }
            return true
        }
        guard !isFailure else { return }

        continuation.yield(data)
        let shouldSuspend = lock.withLock { () -> Bool in
            guard !isTransferSuspended else { return false }
            isTransferSuspended = true
            return true
        }
        guard shouldSuspend else { return }
        dataTask.suspend()
    }

    internal func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let failure = lock.withLock { () -> Error? in
            guard failureStatusCode != nil else { return error }
            let body = String(decoding: failureBody, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
            return ClickHouseError(message: body.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let failure else {
            continuation.finish()
            return
        }
        continuation.finish(throwing: failure)
    }

    private func resumeTransfer() {
        let suspended = lock.withLock { () -> URLSessionDataTask? in
            guard isTransferSuspended else { return nil }
            isTransferSuspended = false
            return task
        }
        suspended?.resume()
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
