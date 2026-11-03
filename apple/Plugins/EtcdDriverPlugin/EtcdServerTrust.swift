//
//  EtcdServerTrust.swift
//  EtcdDriverPlugin
//

import Foundation
import Security
import TableProPluginKit

internal enum EtcdTLSConfigurationError: Error, LocalizedError, Equatable {
    case verifyCANeedsCertificate
    case unreadableCACertificate(path: String)

    var errorDescription: String? {
        switch self {
        case .verifyCANeedsCertificate:
            return String(localized: """
                Verify CA needs a CA certificate. In the etcd section of the Options tab, choose the CA Certificate \
                that signed the server's certificate, or set TLS Mode to Verify Identity.
                """)
        case .unreadableCACertificate(let path):
            return String(
                format: String(localized: "The CA certificate at %@ could not be read as a PEM or DER certificate."),
                path
            )
        }
    }
}

internal struct EtcdServerTrust {
    let anchor: SecCertificate?
    let checksHostname: Bool
    // Behind a tunnel the URL names its loopback forward, so the certificate is checked against this name.
    let serverName: String?

    static func make(tlsMode: String, caCertificatePath: String?, serverName: String?) throws -> EtcdServerTrust? {
        let caPath = (caCertificatePath ?? "").trimmingCharacters(in: .whitespaces)
        switch tlsMode {
        case "VerifyCA":
            guard !caPath.isEmpty else { throw EtcdTLSConfigurationError.verifyCANeedsCertificate }
            return EtcdServerTrust(anchor: try loadAnchor(at: caPath), checksHostname: false, serverName: serverName)
        case "VerifyIdentity":
            let anchor = caPath.isEmpty ? nil : try loadAnchor(at: caPath)
            return EtcdServerTrust(anchor: anchor, checksHostname: true, serverName: serverName)
        default:
            return nil
        }
    }

    func refusal(of serverTrust: SecTrust, host: String) -> SSLHandshakeError? {
        if let anchor {
            if let refusal = Self.refusal(of: SecTrustSetAnchorCertificates(serverTrust, [anchor] as CFArray))
                ?? Self.refusal(of: SecTrustSetAnchorCertificatesOnly(serverTrust, true)) {
                return refusal
            }
        }
        let hostname = checksHostname ? (serverName ?? host) as CFString : nil
        if let refusal = Self.refusal(of: SecTrustSetPolicies(serverTrust, SecPolicyCreateSSL(true, hostname))) {
            return refusal
        }
        var error: CFError?
        guard !SecTrustEvaluateWithError(serverTrust, &error) else { return nil }
        let message = error.map { CFErrorCopyDescription($0) as String } ?? ""
        guard let error, CFErrorGetCode(error) == Int(errSecHostNameMismatch) else {
            return .untrustedCertificate(serverMessage: message)
        }
        return .hostnameMismatch(serverMessage: message)
    }

    private static func refusal(of status: OSStatus) -> SSLHandshakeError? {
        guard status != errSecSuccess else { return nil }
        return .untrustedCertificate(serverMessage: SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)")
    }

    private static func loadAnchor(at path: String) throws -> SecCertificate {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let der = PEMCertificateDecoder.certificateDER(from: data),
              let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw EtcdTLSConfigurationError.unreadableCACertificate(path: path)
        }
        return certificate
    }
}
