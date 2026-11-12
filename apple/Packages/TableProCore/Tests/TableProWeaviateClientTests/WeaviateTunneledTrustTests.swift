import Foundation
import Security
import TableProTLSTestFixtures
@testable import TableProWeaviateClient
import Testing

struct WeaviateTunneledTrustTests {
    // The CA stands in for a root the system trusts, since the transport adds no anchors of its own.
    private func forwardTrust(leaf: String, anchored: Bool = true) throws -> SecTrust {
        let trust = try #require(TLSTestFixtures.serverTrust(leaf: leaf))
        if anchored {
            let der = TLSTestFixtures.der(TLSTestFixtures.serverNameCACertificate)
            let anchor = try #require(SecCertificateCreateWithData(nil, der as CFData))
            try #require(SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess)
        }
        return trust
    }

    @Test("Verify Identity refuses a certificate that names only the loopback forward")
    func refusesTheForwardsName() throws {
        let check = WeaviateTunneledTrust(serverName: "db.example.com", checksServerName: true)
        let trust = try forwardTrust(leaf: TLSTestFixtures.loopbackServerCertificate)
        let refusal = check.refusal(of: trust)
        guard case .transport(let message) = refusal else {
            Issue.record("expected a refusal, got \(String(describing: refusal))")
            return
        }
        #expect(message.contains("db.example.com"))
    }

    @Test("Verify Identity accepts the certificate that names the server behind the tunnel")
    func acceptsTheServersName() throws {
        let check = WeaviateTunneledTrust(serverName: "db.example.com", checksServerName: true)
        let trust = try forwardTrust(leaf: TLSTestFixtures.databaseServerCertificate)
        #expect(check.refusal(of: trust) == nil)
    }

    @Test("Verify CA checks the chain only")
    func chainOnlyIgnoresTheName() throws {
        let check = WeaviateTunneledTrust(serverName: "db.example.com", checksServerName: false)
        let anchored = try forwardTrust(leaf: TLSTestFixtures.loopbackServerCertificate)
        #expect(check.refusal(of: anchored) == nil)
        let unanchored = try forwardTrust(leaf: TLSTestFixtures.loopbackServerCertificate, anchored: false)
        #expect(check.refusal(of: unanchored) != nil)
    }
}
