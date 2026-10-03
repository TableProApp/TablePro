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

    static func make(tlsMode: String, caCertificatePath: String?) throws -> EtcdServerTrust? {
        let caPath = (caCertificatePath ?? "").trimmingCharacters(in: .whitespaces)
        switch tlsMode {
        case "VerifyCA":
            guard !caPath.isEmpty else { throw EtcdTLSConfigurationError.verifyCANeedsCertificate }
            return EtcdServerTrust(anchor: try loadAnchor(at: caPath), checksHostname: false)
        case "VerifyIdentity":
            let anchor = caPath.isEmpty ? nil : try loadAnchor(at: caPath)
            return EtcdServerTrust(anchor: anchor, checksHostname: true)
        default:
            return nil
        }
    }

    func evaluate(_ serverTrust: SecTrust, host: String) -> Bool {
        if let anchor {
            SecTrustSetAnchorCertificates(serverTrust, [anchor] as CFArray)
            SecTrustSetAnchorCertificatesOnly(serverTrust, true)
        }
        let hostname = checksHostname ? host as CFString : nil
        SecTrustSetPolicies(serverTrust, SecPolicyCreateSSL(true, hostname))
        return SecTrustEvaluateWithError(serverTrust, nil)
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
