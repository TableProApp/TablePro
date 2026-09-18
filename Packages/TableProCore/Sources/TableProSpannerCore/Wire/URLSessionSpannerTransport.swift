import Foundation

public final class URLSessionSpannerTransport: SpannerTransport, @unchecked Sendable {
    private let session: URLSession
    private let requestTimeout: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var isClosed = false

    public init(requestTimeout: @escaping @Sendable () -> TimeInterval) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        self.session = URLSession(
            configuration: configuration,
            delegate: SpannerRedirectRefusingDelegate(),
            delegateQueue: nil
        )
        self.requestTimeout = requestTimeout
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let prepared = prepare(request)
        let cancellation = SpannerTaskCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try startTask(cancellation: cancellation) {
                        self.session.dataTask(with: prepared) { data, response, error in
                            continuation.resume(with: Self.completion(data: data, response: response, error: error))
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    public func stream(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        try Task.checkCancellation()
        let prepared = prepare(request)
        let cancellation = SpannerTaskCancellation()
        let (body, bodyContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        bodyContinuation.onTermination = { _ in cancellation.cancel() }
        let receiver = SpannerStreamingTaskDelegate(body: bodyContinuation)
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, Error>) in
                receiver.awaitResponse(continuation)
                do {
                    try startTask(cancellation: cancellation) {
                        let task = self.session.dataTask(with: prepared)
                        task.delegate = receiver
                        return task
                    }
                } catch {
                    receiver.fail(error)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        return (response, body)
    }

    public func close() async {
        let shouldInvalidate = lock.withLock { () -> Bool in
            guard !isClosed else { return false }
            isClosed = true
            return true
        }
        guard shouldInvalidate else { return }
        session.finishTasksAndInvalidate()
    }

    private func prepare(_ request: URLRequest) -> URLRequest {
        var prepared = request
        let timeout = requestTimeout()
        if timeout > 0 {
            prepared.timeoutInterval = timeout
        }
        return prepared
    }

    private func startTask(cancellation: SpannerTaskCancellation, make: () -> URLSessionTask) throws {
        try lock.withLock {
            guard !isClosed else { throw SpannerTransportError.closed }
            let task = make()
            cancellation.attach(task)
            task.resume()
        }
    }

    private static func completion(data: Data?, response: URLResponse?, error: Error?) -> Result<(Data, HTTPURLResponse), Error> {
        if let error {
            return .failure(SpannerURLErrorMapping.transportError(for: error))
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            return .failure(SpannerTransportError.invalidResponse)
        }
        return .success((data ?? Data(), httpResponse))
    }
}

internal final class SpannerTaskCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var isCancelled = false

    func attach(_ task: URLSessionTask) {
        let cancelNow = lock.withLock { () -> Bool in
            self.task = task
            return isCancelled
        }
        if cancelNow {
            task.cancel()
        }
    }

    func cancel() {
        let current = lock.withLock { () -> URLSessionTask? in
            isCancelled = true
            return task
        }
        current?.cancel()
    }
}

internal final class SpannerRedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

internal final class SpannerStreamingTaskDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let maximumChunkSize = 64 * 1_024

    private let lock = NSLock()
    private let body: AsyncThrowingStream<Data, Error>.Continuation
    private var responseContinuation: CheckedContinuation<HTTPURLResponse, Error>?

    init(body: AsyncThrowingStream<Data, Error>.Continuation) {
        self.body = body
    }

    func awaitResponse(_ continuation: CheckedContinuation<HTTPURLResponse, Error>) {
        lock.withLock { responseContinuation = continuation }
    }

    func fail(_ error: Error) {
        let pending = takeResponseContinuation()
        let mapped = SpannerURLErrorMapping.transportError(for: error)
        pending?.resume(throwing: mapped)
        body.finish(throwing: mapped)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse
    ) async -> URLSession.ResponseDisposition {
        guard let httpResponse = response as? HTTPURLResponse else {
            fail(SpannerTransportError.invalidResponse)
            return .cancel
        }
        takeResponseContinuation()?.resume(returning: httpResponse)
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var start = data.startIndex
        while start < data.endIndex {
            let end = data.index(start, offsetBy: Self.maximumChunkSize, limitedBy: data.endIndex) ?? data.endIndex
            body.yield(Data(data[start..<end]))
            start = end
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let pending = takeResponseContinuation()
        guard let error else {
            pending?.resume(throwing: SpannerTransportError.invalidResponse)
            body.finish()
            return
        }
        let mapped = SpannerURLErrorMapping.transportError(for: error)
        pending?.resume(throwing: mapped)
        body.finish(throwing: mapped)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }

    private func takeResponseContinuation() -> CheckedContinuation<HTTPURLResponse, Error>? {
        lock.withLock { () -> CheckedContinuation<HTTPURLResponse, Error>? in
            defer { responseContinuation = nil }
            return responseContinuation
        }
    }
}
