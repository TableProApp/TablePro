import Foundation
import Security
import TableProWeaviateCore

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

// Behind a tunnel the URL names its loopback forward, so URLSession's own check would test 127.0.0.1.
public struct WeaviateTunneledTrust: Sendable, Equatable {
    public let serverName: String
    public let checksServerName: Bool

    public init(serverName: String, checksServerName: Bool) {
        self.serverName = serverName
        self.checksServerName = checksServerName
    }

    func refusal(of trust: SecTrust) -> WeaviateError? {
        let policy = SecPolicyCreateSSL(true, checksServerName ? serverName as CFString : nil)
        let status = SecTrustSetPolicies(trust, policy)
        guard status == errSecSuccess else {
            return Self.untrusted(SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)")
        }
        var error: CFError?
        guard !SecTrustEvaluateWithError(trust, &error) else { return nil }
        let detail = error.map { CFErrorCopyDescription($0) as String } ?? ""
        guard let error, CFErrorGetCode(error) == Int(errSecHostNameMismatch) else { return Self.untrusted(detail) }
        return .transport(String(
            format: String(localized: "The server's TLS certificate does not name %1$@. %2$@"),
            serverName,
            detail
        ))
    }

    private static func untrusted(_ detail: String) -> WeaviateError {
        .transport(String(format: String(localized: "The server's TLS certificate could not be verified. %@"), detail))
    }
}

public protocol WeaviateTransport: Sendable {
    func send(_ request: WeaviateHTTPRequest) async throws -> WeaviateHTTPResponse
    func cancelAll()
}

public final class URLSessionWeaviateTransport: WeaviateTransport, @unchecked Sendable {
    private let session: URLSession
    private let tunneledTrust: WeaviateTunneledTrust?
    private let lock = NSLock()
    private var inFlight: [ObjectIdentifier: URLSessionTask] = [:]

    public init(
        configuration: URLSessionConfiguration = .ephemeral,
        resourceTimeout: TimeInterval,
        skipTLSVerify: Bool = false,
        tunneledTrust: WeaviateTunneledTrust? = nil
    ) {
        configuration.timeoutIntervalForResource = resourceTimeout
        self.tunneledTrust = skipTLSVerify ? nil : tunneledTrust
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

        let tracker = TaskTracker(transport: self, tunneledTrust: tunneledTrust)
        defer { tracker.finish() }
        do {
            let (data, response) = try await session.data(for: urlRequest, delegate: tracker)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw WeaviateError.transport(String(localized: "Weaviate answered with something other than HTTP."))
            }
            return WeaviateHTTPResponse(statusCode: httpResponse.statusCode, body: data)
        } catch let error as URLError where error.code == .cancelled {
            throw tracker.trustRefusal ?? WeaviateError.cancelled
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
    private let tunneledTrust: WeaviateTunneledTrust?
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var refusal: WeaviateError?

    init(transport: URLSessionWeaviateTransport, tunneledTrust: WeaviateTunneledTrust?) {
        self.transport = transport
        self.tunneledTrust = tunneledTrust
    }

    var trustRefusal: WeaviateError? {
        lock.withLock { refusal }
    }

    // Reached only when the session has no delegate of its own, which is every session but the skip-verify one.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let tunneledTrust,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if let refused = tunneledTrust.refusal(of: trust) {
            lock.withLock { refusal = refused }
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
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
