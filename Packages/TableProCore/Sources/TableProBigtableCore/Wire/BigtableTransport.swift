import Foundation

public struct BigtableHTTPRequest: Sendable, Equatable {
    public let method: String
    public let url: URL
    public let headers: [String: String]
    public let body: Data?
    public let timeoutInterval: TimeInterval

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil, timeoutInterval: TimeInterval) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeoutInterval = timeoutInterval
    }
}

public struct BigtableHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }

    public var isSuccess: Bool {
        (200..<300).contains(statusCode)
    }

    func json() throws -> Any {
        guard !body.isEmpty else { return [String: Any]() }
        do {
            return try JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
        } catch {
            throw BigtableError.malformedResponse(String(localized: "Bigtable sent a response that is not JSON."))
        }
    }

    func requireSuccess(_ operation: String) throws {
        guard !isSuccess else { return }
        throw BigtableError.from(status: statusCode, body: body, operation: operation)
    }
}

public protocol BigtableTransport: Sendable {
    func send(_ request: BigtableHTTPRequest) async throws -> BigtableHTTPResponse
    func cancelAll()
}

public struct BigtableCredential: Sendable {
    public let token: @Sendable () async throws -> String
    public let invalidate: @Sendable () async -> Void
    public let quotaProject: String?

    public init(
        token: @escaping @Sendable () async throws -> String,
        invalidate: @escaping @Sendable () async -> Void = {},
        quotaProject: String? = nil
    ) {
        self.token = token
        self.invalidate = invalidate
        self.quotaProject = quotaProject
    }
}

public final class URLSessionBigtableTransport: BigtableTransport, @unchecked Sendable {
    private let session: URLSession
    private let lock = NSLock()
    private var inFlight: [ObjectIdentifier: URLSessionTask] = [:]

    public init(resourceTimeout: TimeInterval) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: BigtableRedirectRefusal(), delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func cancelAll() {
        let tasks = lock.withLock { Array(inFlight.values) }
        tasks.forEach { $0.cancel() }
    }

    public func send(_ request: BigtableHTTPRequest) async throws -> BigtableHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeoutInterval
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let tracker = BigtableTaskTracker(transport: self)
        defer { tracker.finish() }
        do {
            let (data, response) = try await session.data(for: urlRequest, delegate: tracker)
            guard let http = response as? HTTPURLResponse else {
                throw BigtableError.transport(String(localized: "Bigtable answered with something other than HTTP."))
            }
            return BigtableHTTPResponse(statusCode: http.statusCode, body: data)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw BigtableError.transport(error.localizedDescription)
        }
    }

    fileprivate func register(_ task: URLSessionTask) {
        lock.withLock { inFlight[ObjectIdentifier(task)] = task }
    }

    fileprivate func unregister(_ task: URLSessionTask) {
        lock.withLock { inFlight[ObjectIdentifier(task)] = nil }
    }
}

/// A redirect would carry the bearer token to whatever host it names.
private final class BigtableRedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

private final class BigtableTaskTracker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private weak var transport: URLSessionBigtableTransport?
    private let lock = NSLock()
    private var task: URLSessionTask?

    init(transport: URLSessionBigtableTransport) {
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

/// A 401 drops the cached token and retries once, since a token can expire between being cached
/// and being used.
struct BigtableRequester: Sendable {
    let transport: any BigtableTransport
    let credential: BigtableCredential
    let timeout: @Sendable () -> TimeInterval

    func send(method: String, url: URL, json: Any? = nil) async throws -> BigtableHTTPResponse {
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        var response = try await attempt(method, url, body)
        if response.statusCode == 401 {
            await credential.invalidate()
            response = try await attempt(method, url, body)
        }
        return response
    }

    private func attempt(_ method: String, _ url: URL, _ body: Data?) async throws -> BigtableHTTPResponse {
        var headers = ["Authorization": "Bearer " + (try await credential.token())]
        if let project = credential.quotaProject {
            headers["x-goog-user-project"] = project
        }
        if body != nil {
            headers["Content-Type"] = "application/json"
        }
        try Task.checkCancellation()
        return try await transport.send(BigtableHTTPRequest(
            method: method, url: url, headers: headers, body: body, timeoutInterval: timeout()
        ))
    }
}
