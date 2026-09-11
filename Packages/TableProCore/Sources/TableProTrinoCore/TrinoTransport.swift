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

public struct TrinoHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: TrinoHeaderFields
    public let body: Data

    public init(statusCode: Int, headers: TrinoHeaderFields, body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
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
    private let lock = NSLock()
    private var inFlight: [ObjectIdentifier: URLSessionTask] = [:]

    public convenience init(tls: TrinoTLSOptions) {
        self.init(tls: tls, configuration: .ephemeral)
    }

    init(tls: TrinoTLSOptions, configuration: URLSessionConfiguration) {
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegateProxy = TrinoTLSDelegate(tls: tls)
        self.session = URLSession(configuration: configuration, delegate: delegateProxy, delegateQueue: nil)
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

        let tracker = request.method == .delete ? nil : TrinoTaskTracker(transport: self)
        defer { tracker?.finish() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest, delegate: tracker)
        } catch let error as URLError where error.code == .cancelled {
            throw TrinoError.cancelled
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
            body: data
        )
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

private final class TrinoTaskTracker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private weak var transport: URLSessionTrinoTransport?
    private let lock = NSLock()
    private var task: URLSessionTask?

    init(transport: URLSessionTrinoTransport) {
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

private final class TrinoTLSDelegate: NSObject, URLSessionDelegate {
    private let tls: TrinoTLSOptions

    init(tls: TrinoTLSOptions) {
        self.tls = tls
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            handleServerTrust(challenge, completionHandler: completionHandler)
        case NSURLAuthenticationMethodClientCertificate:
            handleClientCertificate(completionHandler: completionHandler)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private func handleServerTrust(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        if tls.mode == .insecure {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }

        if !tls.caCertificatePath.isEmpty {
            guard let caData = try? Data(contentsOf: URL(fileURLWithPath: tls.caCertificatePath)),
                  let caCert = SecCertificateCreateWithData(nil, caData as CFData) else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            SecTrustSetAnchorCertificates(serverTrust, [caCert] as CFArray)
            SecTrustSetAnchorCertificatesOnly(serverTrust, true)
        } else if tls.mode == .full {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        if tls.mode == .caOnly {
            SecTrustSetPolicies(serverTrust, SecPolicyCreateBasicX509())
        }

        if SecTrustEvaluateWithError(serverTrust, nil) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    private func handleClientCertificate(
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard !tls.clientCertificatePath.isEmpty, !tls.clientKeyPath.isEmpty else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let p12Data = Self.buildPkcs12(certPath: tls.clientCertificatePath, keyPath: tls.clientKeyPath) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        var items: CFArray?
        let status = SecPKCS12Import(
            p12Data as CFData,
            [kSecImportExportPassphrase as String: ""] as CFDictionary,
            &items
        )
        guard status == errSecSuccess,
              let itemArray = items as? [[String: Any]],
              let identityRef = itemArray.first?[kSecImportItemIdentity as String],
              CFGetTypeID(identityRef as CFTypeRef) == SecIdentityGetTypeID() else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // swiftlint:disable:next force_cast
        let identity = identityRef as! SecIdentity
        completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
    }

    private static func buildPkcs12(certPath: String, keyPath: String) -> Data? {
        guard let certData = try? Data(contentsOf: URL(fileURLWithPath: certPath)),
              let keyData = try? Data(contentsOf: URL(fileURLWithPath: keyPath)) else {
            return nil
        }
        var certItems: CFArray?
        var certFormat = SecExternalFormat.formatPEMSequence
        var certType = SecExternalItemType.itemTypeCertificate
        let certStatus = SecItemImport(certData as CFData, nil, &certFormat, &certType, [], nil, nil, &certItems)
        guard certStatus == errSecSuccess, let certs = certItems as? [SecCertificate], let cert = certs.first else {
            return nil
        }
        var keyItems: CFArray?
        var keyFormat = SecExternalFormat.formatPEMSequence
        var keyType = SecExternalItemType.itemTypePrivateKey
        let keyStatus = SecItemImport(keyData as CFData, nil, &keyFormat, &keyType, [], nil, nil, &keyItems)
        guard keyStatus == errSecSuccess, let keys = keyItems as? [SecKey], let privateKey = keys.first else {
            return nil
        }
        guard let identity = createIdentity(certificate: cert, privateKey: privateKey) else {
            return nil
        }
        var exportParams = SecItemImportExportKeyParameters()
        var exported: CFData?
        guard SecItemExport(identity, .formatPKCS12, [], &exportParams, &exported) == errSecSuccess,
              let data = exported else {
            return nil
        }
        return data as Data
    }

    private static func createIdentity(certificate: SecCertificate, privateKey: SecKey) -> SecIdentity? {
        var certRef: CFTypeRef?
        let certAddStatus = SecItemAdd([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecReturnRef as String: true
        ] as CFDictionary, &certRef)

        var keyRef: CFTypeRef?
        let keyAddStatus = SecItemAdd([
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: privateKey,
            kSecReturnRef as String: true
        ] as CFDictionary, &keyRef)

        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, certificate, &identity)

        if certAddStatus == errSecSuccess {
            SecItemDelete([
                kSecClass as String: kSecClassCertificate,
                kSecValueRef as String: certRef ?? certificate
            ] as CFDictionary)
        }
        if keyAddStatus == errSecSuccess {
            SecItemDelete([
                kSecClass as String: kSecClassKey,
                kSecValueRef as String: keyRef ?? privateKey
            ] as CFDictionary)
        }
        return status == errSecSuccess ? identity : nil
    }
}
