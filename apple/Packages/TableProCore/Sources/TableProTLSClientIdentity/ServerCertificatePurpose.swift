#if os(macOS)
import Foundation
import Security

// Verify CA checks the chain with the basic X.509 policy, because Apple's SSL policy refuses a private
// CA's long-lived certificate as not standards compliant. The SSL policy was also what required a
// server certificate, so this puts that one check back: a client-only certificate from the same CA
// must not pass as the server.
public enum ServerCertificatePurpose {
    private static let serverAuthentication = Data([0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01])
    private static let anyPurpose = Data([0x55, 0x1D, 0x25, 0x00])

    public static func permitsServerAuthentication(_ certificate: SecCertificate) -> Bool {
        let values = SecCertificateCopyValues(certificate, [kSecOIDExtendedKeyUsage] as CFArray, nil) as? [String: Any]
        guard let usage = values?[kSecOIDExtendedKeyUsage as String] as? [String: Any],
              let purposes = usage[kSecPropertyKeyValue as String] as? [Any]
        else { return true }
        return purposes.contains { purpose in
            guard let oid = purpose as? Data else { return false }
            return oid == serverAuthentication || oid == anyPurpose
        }
    }

    public static func leafPermitsServerAuthentication(_ trust: SecTrust) -> Bool {
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { return false }
        return permitsServerAuthentication(leaf)
    }
}
#endif
