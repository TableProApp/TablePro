import Foundation

public struct GoogleRESTRequest: Sendable, Equatable {
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

public struct GoogleRESTResponse: Sendable, Equatable {
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
}

public protocol GoogleRESTTransport: Sendable {
    func send(_ request: GoogleRESTRequest) async throws -> GoogleRESTResponse
    func cancelAll()
}

public final class URLSessionGoogleRESTTransport: GoogleRESTTransport, @unchecked Sendable {
    private let session: URLSession
    private let transportError: @Sendable (String) -> any Error
    private let lock = NSLock()
    private var inFlight: [ObjectIdentifier: URLSessionTask] = [:]

    public init(resourceTimeout: TimeInterval, transportError: @escaping @Sendable (String) -> any Error) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: GoogleRedirectRefusingDelegate(), delegateQueue: nil)
        self.transportError = transportError
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func cancelAll() {
        let tasks = lock.withLock { Array(inFlight.values) }
        tasks.forEach { $0.cancel() }
    }

    public func send(_ request: GoogleRESTRequest) async throws -> GoogleRESTResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeoutInterval
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let tracker = GoogleRESTTaskTracker(transport: self)
        defer { tracker.finish() }
        do {
            let (data, response) = try await session.data(for: urlRequest, delegate: tracker)
            guard let http = response as? HTTPURLResponse else {
                throw transportError(String(localized: "The server answered with something other than HTTP."))
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key] = value }
            }
            return GoogleRESTResponse(statusCode: http.statusCode, headers: headers, body: data)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw transportError(error.localizedDescription)
        }
    }

    fileprivate func register(_ task: URLSessionTask) {
        lock.withLock { inFlight[ObjectIdentifier(task)] = task }
    }

    fileprivate func unregister(_ task: URLSessionTask) {
        lock.withLock { inFlight[ObjectIdentifier(task)] = nil }
    }
}

private final class GoogleRESTTaskTracker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private weak var transport: URLSessionGoogleRESTTransport?
    private let lock = NSLock()
    private var task: URLSessionTask?

    init(transport: URLSessionGoogleRESTTransport) {
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
