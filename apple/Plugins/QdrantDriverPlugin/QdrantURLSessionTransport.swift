import Foundation
import Security
import TableProPluginKit
import TableProQdrantCore
import TableProTLSClientIdentity

struct QdrantTLS: @unchecked Sendable {
    enum Verification: Sendable, Equatable {
        case none
        case caOnly
        case full
    }

    let verification: Verification
    let anchorDER: Data?
    let clientCredential: URLCredential?

    static let systemDefault = QdrantTLS(verification: .full, anchorDER: nil, clientCredential: nil)

    // Preferred and Required encrypt without checking the certificate, as the SSL Mode picker says.
    static func make(from ssl: SSLConfiguration) throws -> QdrantTLS {
        let verification: Verification
        switch ssl.mode {
        case .disabled, .preferred, .required: verification = .none
        case .verifyCa: verification = .caOnly
        case .verifyIdentity: verification = .full
        }
        let anchor = try anchorCertificate(at: ssl.caCertificatePath, for: verification)
        if verification == .caOnly, anchor == nil {
            throw QdrantError.configuration(String(localized: """
                Verify CA needs a CA certificate. On the connection's Network tab, choose the CA certificate \
                that signed the server's certificate, or set SSL Mode to Verify Identity.
                """))
        }
        return QdrantTLS(verification: verification, anchorDER: anchor, clientCredential: try clientCredential(for: ssl))
    }

    private static func anchorCertificate(at path: String, for verification: Verification) throws -> Data? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard verification != .none, !trimmed.isEmpty else { return nil }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: trimmed)),
              let der = PEMCertificateDecoder.certificateDER(from: data),
              SecCertificateCreateWithData(nil, der as CFData) != nil
        else {
            throw QdrantError.configuration(String(
                format: String(localized: "The CA certificate at %@ could not be read as a PEM or DER certificate."),
                trimmed
            ))
        }
        return der
    }

    private static func clientCredential(for ssl: SSLConfiguration) throws -> URLCredential? {
        let certificatePath = ssl.clientCertificatePath.trimmingCharacters(in: .whitespaces)
        let keyPath = ssl.clientKeyPath.trimmingCharacters(in: .whitespaces)
        guard ssl.isEnabled, !certificatePath.isEmpty else { return nil }
        guard !keyPath.isEmpty else {
            throw QdrantError.configuration(String(localized: """
                A client certificate needs its client key. On the connection's Network tab, choose the \
                client key, or clear the client certificate.
                """))
        }
        do {
            return try TLSClientIdentity.credential(
                certificateFile: URL(fileURLWithPath: certificatePath),
                privateKeyFile: URL(fileURLWithPath: keyPath)
            )
        } catch let failure as TLSClientIdentityError {
            throw QdrantError.configuration(failure.message(certificatePath: certificatePath, keyPath: keyPath))
        }
    }
}

final class URLSessionQdrantTransport: QdrantTransport, @unchecked Sendable {
    private let session: URLSession
    private let tls: QdrantTLS
    private let lock = NSLock()
    private var inFlight: [ObjectIdentifier: URLSessionTask] = [:]

    // No session delegate: URLSession then hands the trust and client certificate challenges to the
    // per-task delegate, which can say why it refused instead of surfacing a bare cancel.
    init(resourceTimeout: TimeInterval, tls: QdrantTLS) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = resourceTimeout
        session = URLSession(configuration: configuration)
        self.tls = tls
    }

    deinit {
        session.invalidateAndCancel()
    }

    func cancelAll() {
        let tasks = lock.withLock { Array(inFlight.values) }
        tasks.forEach { $0.cancel() }
    }

    func send(_ request: QdrantHTTPRequest) async throws -> QdrantHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeoutInterval
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let delegate = QdrantTaskDelegate(transport: self, tls: tls)
        defer { delegate.finish() }
        do {
            let (data, response) = try await session.data(for: urlRequest, delegate: delegate)
            guard let http = response as? HTTPURLResponse else {
                throw QdrantError.transport(String(localized: "Qdrant answered with something other than HTTP."))
            }
            return QdrantHTTPResponse(statusCode: http.statusCode, body: data)
        } catch let error as URLError where error.code == .cancelled {
            if let refusal = delegate.refusal {
                throw QdrantError.transport(refusal)
            }
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

private final class QdrantTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private weak var transport: URLSessionQdrantTransport?
    private let tls: QdrantTLS
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var refusalMessage: String?

    init(transport: URLSessionQdrantTransport, tls: QdrantTLS) {
        self.transport = transport
        self.tls = tls
    }

    var refusal: String? { lock.withLock { refusalMessage } }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.withLock { self.task = task }
        transport?.register(task)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            if let failure = evaluate(trust) {
                lock.withLock { refusalMessage = failure }
                completionHandler(.cancelAuthenticationChallenge, nil)
            } else if tls.verification == .full, tls.anchorDER == nil {
                completionHandler(.performDefaultHandling, nil)
            } else {
                completionHandler(.useCredential, URLCredential(trust: trust))
            }
        case NSURLAuthenticationMethodClientCertificate:
            if let credential = tls.clientCredential {
                completionHandler(.useCredential, credential)
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        default:
            completionHandler(.performDefaultHandling, nil)
        }
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

    private func evaluate(_ trust: SecTrust) -> String? {
        switch tls.verification {
        case .none:
            return nil
        case .full where tls.anchorDER == nil:
            return nil
        case .caOnly, .full:
            if let der = tls.anchorDER, let anchor = SecCertificateCreateWithData(nil, der as CFData) {
                SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, true)
            }
            if tls.verification == .caOnly {
                SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
            }
            var error: CFError?
            guard !SecTrustEvaluateWithError(trust, &error) else { return nil }
            let detail = error.map { CFErrorCopyDescription($0) as String } ?? ""
            return String(format: String(localized: "The server's certificate is not trusted. %@"), detail)
        }
    }
}
