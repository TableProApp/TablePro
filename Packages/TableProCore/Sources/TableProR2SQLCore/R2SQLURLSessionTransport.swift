import Foundation

/// Sends R2 SQL requests with `URLSession.data(for:delegate:)`, so cancelling the Swift task that
/// awaits a request cancels its URL task, and keeps every task in flight so `cancelAll` stops each
/// one. A single stored task handle cancelled whichever request started last, which on a live
/// connection is as often a sidebar metadata read as the query the user stopped.
public final class URLSessionR2SQLTransport: R2SQLTransport, @unchecked Sendable {
    private let session: URLSession
    private let lock = NSLock()
    private var inFlight: [ObjectIdentifier: URLSessionTask] = [:]

    public init(configuration: URLSessionConfiguration = .ephemeral, resourceTimeout: TimeInterval) {
        configuration.timeoutIntervalForResource = resourceTimeout
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func cancelAll() {
        let tasks = lock.withLock { Array(inFlight.values) }
        tasks.forEach { $0.cancel() }
    }

    public func send(_ request: R2SQLHTTPRequest) async throws -> R2SQLHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeoutInterval
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let tracker = TaskTracker(transport: self)
        defer { tracker.finish() }
        do {
            let (data, response) = try await session.data(for: urlRequest, delegate: tracker)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw R2SQLError.transport("R2 SQL answered with something other than HTTP.")
            }
            return R2SQLHTTPResponse(statusCode: httpResponse.statusCode, body: data)
        } catch let error as URLError where error.code == .cancelled {
            throw R2SQLError.cancelled
        } catch let error as URLError {
            throw R2SQLError.transport(error.localizedDescription)
        }
    }

    var inFlightCount: Int {
        lock.withLock { inFlight.count }
    }

    fileprivate func register(_ task: URLSessionTask) {
        lock.withLock { inFlight[ObjectIdentifier(task)] = task }
    }

    fileprivate func unregister(_ task: URLSessionTask) {
        lock.withLock { inFlight[ObjectIdentifier(task)] = nil }
    }
}

private final class TaskTracker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private weak var transport: URLSessionR2SQLTransport?
    private let lock = NSLock()
    private var task: URLSessionTask?

    init(transport: URLSessionR2SQLTransport) {
        self.transport = transport
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.withLock { self.task = task }
        transport?.register(task)
    }

    func finish() {
        guard let task = lock.withLock({ task }) else { return }
        transport?.unregister(task)
    }
}
