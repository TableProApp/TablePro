import Foundation

public struct FirebaseHTTPRequest: Sendable, Equatable {
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

public struct FirebaseHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public var isSuccess: Bool {
        (200..<300).contains(statusCode)
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public func json() throws -> FirebaseJSON {
        guard !body.isEmpty else { return .null }
        return try FirebaseJSON.parse(body)
    }

    func requireSuccess(_ operation: String) throws {
        guard !isSuccess else { return }
        throw FirebaseError.from(status: statusCode, body: body, operation: operation)
    }
}

public protocol FirebaseTransport: Sendable {
    func send(_ request: FirebaseHTTPRequest) async throws -> FirebaseHTTPResponse
    func cancelAll()
}

/// The emulators take the fixed token `owner`, which bypasses the security rules there.
public struct FirebaseCredential: Sendable {
    public let token: @Sendable () async throws -> String?
    public let invalidate: @Sendable () async -> Void
    public let quotaProject: String?

    public init(
        token: @escaping @Sendable () async throws -> String?,
        invalidate: @escaping @Sendable () async -> Void = {},
        quotaProject: String? = nil
    ) {
        self.token = token
        self.invalidate = invalidate
        self.quotaProject = quotaProject
    }

    public static let emulator = FirebaseCredential(token: { "owner" })
}

public final class URLSessionFirebaseTransport: FirebaseTransport, @unchecked Sendable {
    private let session: URLSession
    private let lock = NSLock()
    private var inFlight: [ObjectIdentifier: URLSessionTask] = [:]

    public init(resourceTimeout: TimeInterval) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: FirebaseRedirectRefusal(), delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func cancelAll() {
        let tasks = lock.withLock { Array(inFlight.values) }
        tasks.forEach { $0.cancel() }
    }

    public func send(_ request: FirebaseHTTPRequest) async throws -> FirebaseHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeoutInterval
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let tracker = FirebaseTaskTracker(transport: self)
        defer { tracker.finish() }
        do {
            let (data, response) = try await session.data(for: urlRequest, delegate: tracker)
            guard let http = response as? HTTPURLResponse else {
                throw FirebaseError.transport(String(localized: "Firebase answered with something other than HTTP."))
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key] = value }
            }
            return FirebaseHTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw FirebaseError.transport(error.localizedDescription)
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
private final class FirebaseRedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

private final class FirebaseTaskTracker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private weak var transport: URLSessionFirebaseTransport?
    private let lock = NSLock()
    private var task: URLSessionTask?

    init(transport: URLSessionFirebaseTransport) {
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
struct FirebaseRequester: Sendable {
    let transport: any FirebaseTransport
    let credential: FirebaseCredential
    let timeout: @Sendable () -> TimeInterval

    func send(
        method: String,
        url: URL,
        body: Data? = nil,
        headers: [String: String] = [:],
        timeoutOverride: TimeInterval? = nil
    ) async throws -> FirebaseHTTPResponse {
        var response = try await attempt(method, url, body, headers, timeoutOverride)
        if response.statusCode == 401 {
            await credential.invalidate()
            response = try await attempt(method, url, body, headers, timeoutOverride)
        }
        return response
    }

    private func attempt(
        _ method: String,
        _ url: URL,
        _ body: Data?,
        _ extraHeaders: [String: String],
        _ timeoutOverride: TimeInterval?
    ) async throws -> FirebaseHTTPResponse {
        var headers = extraHeaders
        if let token = try await credential.token() {
            headers["Authorization"] = "Bearer " + token
        }
        if let project = credential.quotaProject, headers["x-goog-user-project"] == nil {
            headers["x-goog-user-project"] = project
        }
        if body != nil {
            headers["Content-Type"] = "application/json"
        }
        try Task.checkCancellation()
        return try await transport.send(FirebaseHTTPRequest(
            method: method,
            url: url,
            headers: headers,
            body: body,
            timeoutInterval: timeoutOverride ?? timeout()
        ))
    }

    static func queryString(_ items: [URLQueryItem]) -> String? {
        guard !items.isEmpty else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        func encoded(_ text: String) -> String {
            text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
        }
        return items.map { encoded($0.name) + "=" + encoded($0.value ?? "") }.joined(separator: "&")
    }
}
