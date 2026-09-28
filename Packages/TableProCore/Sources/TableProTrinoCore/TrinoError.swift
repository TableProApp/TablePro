import Foundation

public struct TrinoQueryError: Decodable, Sendable, Equatable {
    public let message: String
    public let errorCode: Int?
    public let errorName: String?
    public let errorType: String?

    public init(message: String, errorCode: Int? = nil, errorName: String? = nil, errorType: String? = nil) {
        self.message = message
        self.errorCode = errorCode
        self.errorName = errorName
        self.errorType = errorType
    }

    private enum CodingKeys: String, CodingKey {
        case message, errorCode, errorName, errorType
    }
}

public enum TrinoTLSFailureKind: Sendable, Equatable {
    case serverRejectedPlaintext
    case untrustedCertificate
    case hostnameMismatch
    case clientCertificateRequired
    case clientCertificateRejected
}

public enum TrinoCredentialKind: Sendable, Equatable {
    case password
    case accessToken
}

public enum TrinoRedirectAdvice: Sendable, Equatable {
    case checkAddress
    case turnOnTLS(port: Int)
}

public enum TrinoError: Error, LocalizedError, Equatable {
    case invalidConfiguration(String)
    case notConnected
    case transport(String)
    case httpStatus(code: Int, body: String)
    case redirected(statusCode: Int, location: String?, advice: TrinoRedirectAdvice)
    case credentialsRequireTLS(TrinoCredentialKind)
    case tlsHandshakeFailed(kind: TrinoTLSFailureKind, serverMessage: String)
    case authenticationFailed(String)
    case query(TrinoQueryError)
    case invalidResponse(String)
    case cancelled
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail):
            return detail
        case .notConnected:
            return "Not connected to Trino"
        case .transport(let detail):
            return detail
        case .httpStatus(let code, let body):
            return body.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(body)"
        case .redirected(let statusCode, let location, let advice):
            return Self.describeRedirect(statusCode: statusCode, location: location, advice: advice)
        case .credentialsRequireTLS(let kind):
            return Self.describe(kind)
        case .tlsHandshakeFailed(let kind, let serverMessage):
            return Self.describe(kind, serverMessage: serverMessage)
        case .authenticationFailed(let detail):
            return detail
        case .query(let error):
            if let name = error.errorName, !name.isEmpty {
                return "\(name): \(error.message)"
            }
            return error.message
        case .invalidResponse(let detail):
            return detail
        case .cancelled:
            return "Query was cancelled"
        case .timedOut:
            return "Timed out waiting for Trino"
        }
    }

    private static func describe(_ kind: TrinoTLSFailureKind, serverMessage: String) -> String {
        let reason: String
        switch kind {
        case .serverRejectedPlaintext:
            reason = "The server accepts only HTTPS, and SSL is off for this connection. Set SSL Mode to Verify Identity."
        case .untrustedCertificate:
            reason = "The server's TLS certificate is not trusted."
        case .hostnameMismatch:
            reason = "The server's TLS certificate does not match the host."
        case .clientCertificateRequired:
            reason = "The server asked for a client certificate, and none is set for this connection."
        case .clientCertificateRejected:
            reason = "The server did not accept the client certificate."
        }
        return serverMessage.isEmpty ? reason : "\(reason) \(serverMessage)"
    }

    private static func describe(_ kind: TrinoCredentialKind) -> String {
        switch kind {
        case .password:
            return "A password is sent only over TLS, and SSL Mode is Disabled. Set SSL Mode to Verify Identity, "
                + "or clear the password if the cluster has no authentication."
        case .accessToken:
            return "An access token is sent only over TLS, and SSL Mode is Disabled. Set SSL Mode to Verify "
                + "Identity, or clear the Access Token if the cluster has no authentication."
        }
    }

    private static func describeRedirect(statusCode: Int, location: String?, advice: TrinoRedirectAdvice) -> String {
        guard let location else {
            return "The server answered with HTTP \(statusCode) and no address. "
                + "Trino never redirects, so a proxy in front of it sent this. Check the host, port and SSL Mode."
        }
        switch advice {
        case .turnOnTLS(let port):
            return "The server redirected the request to \(location), which needs HTTPS. "
                + "Set Port to \(port) and SSL Mode to Verify Identity."
        case .checkAddress:
            return "The server redirected the request to \(location). TablePro does not follow redirects, "
                + "and Trino never sends one, so a proxy in front of it did. Check the host, port and SSL Mode."
        }
    }
}
