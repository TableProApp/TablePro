#if os(macOS)
import Foundation
import Security
import TableProTLSClientIdentity
import TableProTLSTestFixtures
import Testing

struct ServerCertificatePurposeTests {
    private func certificate(_ pem: String) throws -> SecCertificate {
        try #require(SecCertificateCreateWithData(nil, TLSTestFixtures.der(pem) as CFData))
    }

    private func trust(_ leafPEM: String) throws -> SecTrust {
        var trust: SecTrust?
        SecTrustCreateWithCertificates(try certificate(leafPEM), SecPolicyCreateBasicX509(), &trust)
        let created = try #require(trust)
        SecTrustSetAnchorCertificates(created, [try certificate(TLSTestFixtures.caCertificate)] as CFArray)
        SecTrustSetAnchorCertificatesOnly(created, true)
        return created
    }

    @Test("A client-only certificate chains to the CA under the X.509 policy but is not a server's")
    func clientCertificateRefused() throws {
        let trust = try trust(TLSTestFixtures.clientCertificate)
        #expect(SecTrustEvaluateWithError(trust, nil))
        #expect(!ServerCertificatePurpose.leafPermitsServerAuthentication(trust))
    }

    @Test("A server certificate and a certificate with no key usage list both pass")
    func serverCertificatePasses() throws {
        let trust = try trust(TLSTestFixtures.serverCertificate)
        #expect(SecTrustEvaluateWithError(trust, nil))
        #expect(ServerCertificatePurpose.leafPermitsServerAuthentication(trust))
        #expect(ServerCertificatePurpose.permitsServerAuthentication(try certificate(TLSTestFixtures.caCertificate)))
    }
}
#endif
