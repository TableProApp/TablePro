import Foundation
import Security
import TableProPluginKit
import TableProTLSClientIdentity
import TableProTrinoCore

enum TrinoSSLMapping {
    static func tlsOptions(for ssl: SSLConfiguration) throws -> TrinoTLSOptions {
        let mode: TrinoTLSOptions.VerificationMode
        switch ssl.mode {
        case .disabled, .preferred, .required:
            mode = .insecure
        case .verifyCa:
            mode = .caOnly
        case .verifyIdentity:
            mode = .full
        }
        let anchor = try anchorCertificate(at: ssl.caCertificatePath, for: mode)
        if mode == .caOnly, anchor == nil {
            throw TrinoError.invalidConfiguration(String(
                localized: """
                    Verify CA needs a CA certificate. On the connection's Network tab, choose the CA certificate \
                    that signed the server's certificate, or set SSL Mode to Verify Identity.
                    """
            ))
        }
        return TrinoTLSOptions(mode: mode, anchorCertificate: anchor, clientCredential: try clientCredential(for: ssl))
    }

    static func anchorCertificate(at path: String, for mode: TrinoTLSOptions.VerificationMode) throws -> Data? {
        let trimmedPath = path.trimmingCharacters(in: .whitespaces)
        guard mode != .insecure, !trimmedPath.isEmpty else { return nil }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: trimmedPath)),
              let der = PEMCertificateDecoder.certificateDER(from: data),
              SecCertificateCreateWithData(nil, der as CFData) != nil else {
            throw TrinoError.invalidConfiguration(String(
                format: String(localized: "The CA certificate at %@ could not be read as a PEM or DER certificate."),
                trimmedPath
            ))
        }
        return der
    }

    static func clientCredential(for ssl: SSLConfiguration) throws -> URLCredential? {
        let certificatePath = ssl.clientCertificatePath.trimmingCharacters(in: .whitespaces)
        let keyPath = ssl.clientKeyPath.trimmingCharacters(in: .whitespaces)
        guard ssl.isEnabled, !certificatePath.isEmpty else { return nil }
        guard !keyPath.isEmpty else {
            throw TrinoError.invalidConfiguration(String(
                localized: """
                    A client certificate needs its client key. On the connection's Network tab, choose the \
                    client key, or clear the client certificate.
                    """
            ))
        }
        do {
            return try TLSClientIdentity.credential(
                certificateFile: URL(fileURLWithPath: certificatePath),
                privateKeyFile: URL(fileURLWithPath: keyPath)
            )
        } catch let failure as TLSClientIdentityError {
            throw TrinoError.invalidConfiguration(failure.message(certificatePath: certificatePath, keyPath: keyPath))
        }
    }
}

extension TrinoCredentialKind {
    var plaintextRefusal: TrinoError {
        switch self {
        case .password:
            return .invalidConfiguration(String(
                localized: """
                    A password is sent only over TLS, and SSL Mode is Disabled. Set SSL Mode to Verify Identity, \
                    or clear the password if the cluster has no authentication.
                    """
            ))
        case .accessToken:
            return .invalidConfiguration(String(
                localized: """
                    An access token is sent only over TLS, and SSL Mode is Disabled. Set SSL Mode to Verify \
                    Identity, or clear the Access Token if the cluster has no authentication.
                    """
            ))
        }
    }
}

extension TrinoTLSFailureKind {
    func sslHandshakeError(serverMessage: String) -> SSLHandshakeError {
        switch self {
        case .serverRejectedPlaintext:
            return .serverRejectedPlaintext(serverMessage: serverMessage)
        case .untrustedCertificate:
            return .untrustedCertificate(serverMessage: serverMessage)
        case .hostnameMismatch:
            return .hostnameMismatch(serverMessage: serverMessage)
        case .clientCertificateRequired:
            return .clientCertRequired(serverMessage: serverMessage)
        case .clientCertificateRejected:
            return .unknown(serverMessage: String(
                format: String(localized: "The server did not accept the client certificate. %@"),
                serverMessage
            ))
        }
    }
}
