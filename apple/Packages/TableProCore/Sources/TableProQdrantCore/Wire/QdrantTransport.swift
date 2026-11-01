import Foundation

public struct QdrantHTTPRequest: Sendable, Equatable {
    public let method: String
    public let url: URL
    public let headers: [String: String]
    public let body: Data?
    public let timeoutInterval: TimeInterval

    public init(method: String, url: URL, headers: [String: String], body: Data?, timeoutInterval: TimeInterval) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeoutInterval = timeoutInterval
    }
}

public struct QdrantHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }

    public var json: Any? {
        try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
    }

    public var text: String {
        String(data: body, encoding: .utf8) ?? ""
    }
}

public protocol QdrantTransport: Sendable {
    func send(_ request: QdrantHTTPRequest) async throws -> QdrantHTTPResponse
    func cancelAll()
}

public final class URLSessionQdrantTransport: QdrantTransport, @unchecked Sendable {
    private let session: URLSession
    private let lock = NSLock()
    private var inFlight: [ObjectIdentifier: URLSessionTask] = [:]

    public init(
        configuration: URLSessionConfiguration = .ephemeral,
        resourceTimeout: TimeInterval,
        skipTLSVerify: Bool = false
    ) {
        configuration.timeoutIntervalForResource = resourceTimeout
        session = URLSession(
            configuration: configuration,
            delegate: skipTLSVerify ? TrustingTLSDelegate() : nil,
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func cancelAll() {
        let tasks = lock.withLock { Array(inFlight.values) }
        tasks.forEach { $0.cancel() }
    }

    public func send(_ request: QdrantHTTPRequest) async throws -> QdrantHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeoutInterval
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let tracker = TaskTracker(transport: self)
        defer { tracker.finish() }
        do {
            let (data, response) = try await session.data(for: urlRequest, delegate: tracker)
            guard let http = response as? HTTPURLResponse else {
                throw QdrantError.transport(String(localized: "Qdrant answered with something other than HTTP."))
            }
            return QdrantHTTPResponse(statusCode: http.statusCode, body: data)
        } catch let error as URLError where error.code == .cancelled {
            throw QdrantError.cancelled
        } catch let error as QdrantError {
            throw error
        } catch let error as URLError {
            throw QdrantError.transport(error.localizedDescription)
        }
    }

    fileprivate func register(_ task: URLSessionTask) {
        lock.withLock { inFlight[ObjectIdentifier(task)] = task }
    }

    fileprivate func unregister(_ task: URLSessionTask) {
        lock.withLock { inFlight[ObjectIdentifier(task)] = nil }
    }
}

private final class TrustingTLSDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

private final class TaskTracker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private weak var transport: URLSessionQdrantTransport?
    private let lock = NSLock()
    private var task: URLSessionTask?

    init(transport: URLSessionQdrantTransport) {
        self.transport = transport
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.withLock { self.task = task }
        transport?.register(task)
    }

    // A redirect would carry the API key to wherever it points.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func finish() {
        guard let task = lock.withLock({ task }) else { return }
        transport?.unregister(task)
    }
}
