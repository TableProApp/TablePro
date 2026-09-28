import Foundation
import Security

public struct TrinoHeaderFields: Sendable, Equatable {
    private let storage: [String: String]

    public init(_ fields: [String: String]) {
        var map: [String: String] = [:]
        for (key, value) in fields {
            map[key.lowercased()] = value
        }
        storage = map
    }

    public init(httpResponse: HTTPURLResponse) {
        var map: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            guard let name = key as? String, let text = value as? String else { continue }
            map[name.lowercased()] = text
        }
        storage = map
    }

    public func first(_ name: String) -> String? {
        storage[name.lowercased()]
    }

    public func contains(_ name: String) -> Bool {
        storage[name.lowercased()] != nil
    }

    public func all(_ name: String) -> [String] {
        guard let value = storage[name.lowercased()] else { return [] }
        return value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

public struct TrinoHTTPRequest: Sendable {
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case delete = "DELETE"
    }

    public let method: Method
    public let url: URL
    public let headers: [String: String]
    public let body: Data?
    public let timeoutSeconds: Int

    public init(method: Method, url: URL, headers: [String: String], body: Data? = nil, timeoutSeconds: Int = 60) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeoutSeconds = timeoutSeconds
    }
}

public enum TrinoClientCertificateRequest: Sendable, Equatable {
    case unanswered
    case answered
}

public struct TrinoHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: TrinoHeaderFields
    public let body: Data
    public let clientCertificateRequest: TrinoClientCertificateRequest?

    public init(
        statusCode: Int,
        headers: TrinoHeaderFields,
        body: Data,
        clientCertificateRequest: TrinoClientCertificateRequest? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.clientCertificateRequest = clientCertificateRequest
    }

    public func retryAfterSeconds() -> Double? {
        guard let value = headers.first("Retry-After"), let seconds = Double(value) else { return nil }
        return seconds
    }
}

public protocol TrinoTransport: Sendable {
    func send(_ request: TrinoHTTPRequest) async throws -> TrinoHTTPResponse
    func cancelAll()
}

/// Sends with `URLSession.data(for:delegate:)`, so cancelling the Swift task that awaits a request
/// cancels its URL task, and keeps every request in flight so `cancelAll` stops each one. A DELETE
/// is never tracked: it is how a statement tells Trino to stop, and a cancel must not cancel it.
public final class URLSessionTrinoTransport: NSObject, TrinoTransport, @unchecked Sendable {
    private let session: URLSession
    private let tls: TrinoTLSOptions
    private let lock = NSLock()
    private var inFlight: [ObjectIdentifier: URLSessionTask] = [:]

    public convenience init(tls: TrinoTLSOptions) {
        self.init(tls: tls, configuration: .ephemeral)
    }

    init(tls: TrinoTLSOptions, configuration: URLSessionConfiguration) {
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.tls = tls
        self.session = URLSession(configuration: configuration)
        super.init()
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func cancelAll() {
        let tasks = lock.withLock { Array(inFlight.values) }
        tasks.forEach { $0.cancel() }
    }

    public func send(_ request: TrinoHTTPRequest) async throws -> TrinoHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = TimeInterval(request.timeoutSeconds)
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let delegate = TrinoTaskDelegate(
            challenges: TrinoTLSChallengeHandler(tls: tls),
            transport: request.method == .delete ? nil : self
        )
        defer { delegate.finish() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest, delegate: delegate)
        } catch let error as URLError {
            throw Self.failure(
                for: error,
                refusedTrust: delegate.refusedTrust,
                clientCertificateRequest: delegate.clientCertificateRequest,
                serverAnswered: delegate.serverAnswered
            )
        } catch is CancellationError {
            throw TrinoError.cancelled
        } catch {
            throw TrinoError.transport(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TrinoError.invalidResponse("Response was not HTTP")
        }
        return TrinoHTTPResponse(
            statusCode: httpResponse.statusCode,
            headers: TrinoHeaderFields(httpResponse: httpResponse),
            body: data,
            clientCertificateRequest: delegate.clientCertificateRequest
        )
    }

    static func failure(
        for error: URLError,
        refusedTrust: TrinoTrustRefusal?,
        clientCertificateRequest: TrinoClientCertificateRequest?,
        serverAnswered: Bool = false
    ) -> TrinoError {
        if !serverAnswered, let kind = clientCertificateRequest?.failureKind(for: error.code) {
            return .tlsHandshakeFailed(kind: kind, serverMessage: error.localizedDescription)
        }
        switch error.code {
        case .cancelled:
            guard let refusedTrust else { return .cancelled }
            return .tlsHandshakeFailed(kind: refusedTrust.kind, serverMessage: refusedTrust.message)
        case .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return .tlsHandshakeFailed(kind: trustFailureKind(of: error), serverMessage: error.localizedDescription)
        default:
            return .transport(error.localizedDescription)
        }
    }

    private static func trustFailureKind(of error: URLError) -> TrinoTLSFailureKind {
        guard let peerTrust = error.userInfo[NSURLErrorFailingURLPeerTrustErrorKey],
              CFGetTypeID(peerTrust as CFTypeRef) == SecTrustGetTypeID() else {
            return .untrustedCertificate
        }
        let trust = unsafeDowncast(peerTrust as AnyObject, to: SecTrust.self)
        var evaluationError: CFError?
        guard !SecTrustEvaluateWithError(trust, &evaluationError) else { return .untrustedCertificate }
        return TrinoTLSChallengeHandler.failureKind(of: evaluationError)
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

extension TrinoClientCertificateRequest {
    private static let rejectionCodes: Set<URLError.Code> = [
        .networkConnectionLost, .secureConnectionFailed, .clientCertificateRejected, .clientCertificateRequired
    ]
    private static let requirementCodes: Set<URLError.Code> = [.secureConnectionFailed, .clientCertificateRequired]

    func failureKind(for code: URLError.Code) -> TrinoTLSFailureKind? {
        switch self {
        case .answered:
            return Self.rejectionCodes.contains(code) ? .clientCertificateRejected : nil
        case .unanswered:
            return Self.requirementCodes.contains(code) ? .clientCertificateRequired : nil
        }
    }
}

struct TrinoTrustRefusal: Sendable, Equatable {
    let kind: TrinoTLSFailureKind
    let message: String
}

extension TrinoTLSOptions {
    var missingAnchorRefusal: TrinoTrustRefusal? {
        guard mode == .caOnly, anchorCertificate == nil else { return nil }
        return TrinoTrustRefusal(
            kind: .untrustedCertificate,
            message: "Verify CA has no CA certificate to check the server against."
        )
    }
}

private final class TrinoTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private weak var transport: URLSessionTrinoTransport?
    private let challenges: TrinoTLSChallengeHandler
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var refusal: TrinoTrustRefusal?
    private var certificateRequest: TrinoClientCertificateRequest?
    private var answered = false

    init(challenges: TrinoTLSChallengeHandler, transport: URLSessionTrinoTransport?) {
        self.challenges = challenges
        self.transport = transport
    }

    var refusedTrust: TrinoTrustRefusal? {
        lock.withLock { refusal }
    }

    var clientCertificateRequest: TrinoClientCertificateRequest? {
        lock.withLock { certificateRequest }
    }

    var serverAnswered: Bool {
        lock.withLock { answered }
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        guard let transport else { return }
        lock.withLock { self.task = task }
        transport.register(task)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let answer = challenges.answer(challenge)
        if let refused = answer.refusal {
            lock.withLock { refusal = refused }
        }
        if let request = answer.clientCertificateRequest {
            lock.withLock { certificateRequest = request }
        }
        completionHandler(answer.disposition, answer.credential)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let responded = metrics.transactionMetrics.contains { $0.responseStartDate != nil }
        lock.withLock { answered = responded }
    }

    func finish() {
        guard let task = lock.withLock({ task }) else { return }
        transport?.unregister(task)
    }
}

struct TrinoChallengeAnswer {
    let disposition: URLSession.AuthChallengeDisposition
    let credential: URLCredential?
    var refusal: TrinoTrustRefusal?
    var clientCertificateRequest: TrinoClientCertificateRequest?

    static let defaultHandling = TrinoChallengeAnswer(disposition: .performDefaultHandling, credential: nil)

    static func refuse(_ kind: TrinoTLSFailureKind, message: String) -> TrinoChallengeAnswer {
        TrinoChallengeAnswer(
            disposition: .cancelAuthenticationChallenge,
            credential: nil,
            refusal: TrinoTrustRefusal(kind: kind, message: message)
        )
    }
}

struct TrinoTLSChallengeHandler {
    let tls: TrinoTLSOptions

    func answer(_ challenge: URLAuthenticationChallenge) -> TrinoChallengeAnswer {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            return answerServerTrust(challenge)
        case NSURLAuthenticationMethodClientCertificate:
            return answerClientCertificate()
        default:
            return .defaultHandling
        }
    }

    private func answerServerTrust(_ challenge: URLAuthenticationChallenge) -> TrinoChallengeAnswer {
        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            return .defaultHandling
        }
        if tls.mode == .insecure {
            return TrinoChallengeAnswer(disposition: .useCredential, credential: URLCredential(trust: serverTrust))
        }
        if let refusal = tls.missingAnchorRefusal {
            return TrinoChallengeAnswer(disposition: .cancelAuthenticationChallenge, credential: nil, refusal: refusal)
        }
        if tls.mode == .full, tls.anchorCertificate == nil {
            return .defaultHandling
        }
        if let anchorDER = tls.anchorCertificate {
            guard let anchor = SecCertificateCreateWithData(nil, anchorDER as CFData) else {
                return .refuse(.untrustedCertificate, message: "The CA certificate is not a DER or PEM certificate.")
            }
            SecTrustSetAnchorCertificates(serverTrust, [anchor] as CFArray)
            SecTrustSetAnchorCertificatesOnly(serverTrust, true)
        }
        if tls.mode == .caOnly {
            SecTrustSetPolicies(serverTrust, SecPolicyCreateBasicX509())
        }
        var error: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &error) else {
            return .refuse(Self.failureKind(of: error), message: error.map { CFErrorCopyDescription($0) as String } ?? "")
        }
        return TrinoChallengeAnswer(disposition: .useCredential, credential: URLCredential(trust: serverTrust))
    }

    static func failureKind(of error: CFError?) -> TrinoTLSFailureKind {
        guard let error, CFErrorGetCode(error) == Int(errSecHostNameMismatch) else { return .untrustedCertificate }
        return .hostnameMismatch
    }

    private func answerClientCertificate() -> TrinoChallengeAnswer {
        guard let credential = tls.clientCredential else {
            return TrinoChallengeAnswer(
                disposition: .performDefaultHandling,
                credential: nil,
                clientCertificateRequest: .unanswered
            )
        }
        return TrinoChallengeAnswer(disposition: .useCredential, credential: credential, clientCertificateRequest: .answered)
    }
}
