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
}

public final class URLSessionTrinoTransport: NSObject, TrinoTransport, @unchecked Sendable {
    private let session: URLSession

    public init(tls: TrinoTLSOptions) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegateProxy = TrinoTLSDelegate(tls: tls)
        self.session = URLSession(configuration: configuration, delegate: delegateProxy, delegateQueue: nil)
        super.init()
    }

    public func send(_ request: TrinoHTTPRequest) async throws -> TrinoHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = TimeInterval(request.timeoutSeconds)
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
            let task = session.dataTask(with: urlRequest) { data, response, error in
                if let error {
                    if (error as? URLError)?.code == .cancelled {
                        continuation.resume(throwing: TrinoError.cancelled)
                    } else {
                        continuation.resume(throwing: TrinoError.transport(error.localizedDescription))
                    }
                    return
                }
                guard let data, let response else {
                    continuation.resume(throwing: TrinoError.invalidResponse("Empty response from Trino"))
                    return
                }
                continuation.resume(returning: (data, response))
            }
            task.resume()
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
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
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
}
