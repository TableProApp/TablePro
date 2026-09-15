import Foundation

public struct WeaviateHTTPRequest: Sendable, Equatable {
    public let method: String
    public let url: URL
    public let headers: [String: String]
    public let body: Data?
    public let timeoutInterval: TimeInterval

    public init(
        method: String,
        url: URL,
        headers: [String: String],
        body: Data?,
        timeoutInterval: TimeInterval
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeoutInterval = timeoutInterval
    }
}

public struct WeaviateHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let body: Data
    private let parsed: ParsedResponseJSON

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
        self.parsed = ParsedResponseJSON(body)
    }

    /// A filtered browse reads this two or three times, and a page of 1536-dimension vectors is
    /// several megabytes, so the body is parsed once and the result held.
    public var json: Any? {
        parsed.value
    }

    public var text: String {
        String(data: body, encoding: .utf8) ?? ""
    }

    public static func == (lhs: WeaviateHTTPResponse, rhs: WeaviateHTTPResponse) -> Bool {
        lhs.statusCode == rhs.statusCode && lhs.body == rhs.body
    }
}

private final class ParsedResponseJSON: @unchecked Sendable {
    private let body: Data
    private let lock = NSLock()
    private var cachedValue: Any?
    private var hasParsed = false

    init(_ body: Data) {
        self.body = body
    }

    var value: Any? {
        lock.withLock {
            if !hasParsed {
                cachedValue = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
                hasParsed = true
            }
            return cachedValue
        }
    }
}

public protocol WeaviateTransport: Sendable {
    func send(_ request: WeaviateHTTPRequest) async throws -> WeaviateHTTPResponse
    func cancelAll()
}

public final class URLSessionWeaviateTransport: WeaviateTransport, @unchecked Sendable {
    private let session: URLSession
    private let lock = NSLock()
    private var inFlight: [ObjectIdentifier: URLSessionTask] = [:]

    public init(
        configuration: URLSessionConfiguration = .ephemeral,
        resourceTimeout: TimeInterval,
        skipTLSVerify: Bool = false
    ) {
        configuration.timeoutIntervalForResource = resourceTimeout
        if skipTLSVerify {
            let delegate = InsecureTLSDelegate()
            session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        } else {
            session = URLSession(configuration: configuration)
        }
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func cancelAll() {
        let tasks = lock.withLock { Array(inFlight.values) }
        tasks.forEach { $0.cancel() }
    }

    public func send(_ request: WeaviateHTTPRequest) async throws -> WeaviateHTTPResponse {
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
            guard let httpResponse = response as? HTTPURLResponse else {
                throw WeaviateError.transport(String(localized: "Weaviate answered with something other than HTTP."))
            }
            return WeaviateHTTPResponse(statusCode: httpResponse.statusCode, body: data)
        } catch let error as URLError where error.code == .cancelled {
            throw WeaviateError.cancelled
        } catch let error as WeaviateError {
            throw error
        } catch let error as URLError {
            throw WeaviateError.transport(error.localizedDescription)
        }
    }

    fileprivate func register(_ task: URLSessionTask) {
        lock.withLock { inFlight[ObjectIdentifier(task)] = task }
    }

    fileprivate func unregister(_ task: URLSessionTask) {
        lock.withLock { inFlight[ObjectIdentifier(task)] = nil }
    }
}

private final class InsecureTLSDelegate: NSObject, URLSessionDelegate {
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
    private weak var transport: URLSessionWeaviateTransport?
    private let lock = NSLock()
    private var task: URLSessionTask?

    init(transport: URLSessionWeaviateTransport) {
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
