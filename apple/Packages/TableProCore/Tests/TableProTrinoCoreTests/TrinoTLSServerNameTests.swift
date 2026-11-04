import Foundation
import Security
import TableProTLSTestFixtures
@testable import TableProTrinoCore
import Testing

private final class IgnoringChallengeSender: NSObject, URLAuthenticationChallengeSender, @unchecked Sendable {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

private final class ServerTrustProtectionSpace: URLProtectionSpace, @unchecked Sendable {
    private let trust: SecTrust

    init(trust: SecTrust, host: String) {
        self.trust = trust
        super.init(
            host: host,
            port: 8_443,
            protocol: NSURLProtectionSpaceHTTPS,
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var serverTrust: SecTrust? { trust }
}

struct TrinoTLSServerNameTests {
    private func handlerAnswer(
        leaf: String,
        dialedHost: String = "127.0.0.1",
        mode: TrinoTLSOptions.VerificationMode,
        serverName: String?
    ) throws -> TrinoChallengeAnswer {
        let trust = try #require(TLSTestFixtures.serverTrust(leaf: leaf, dialedHost: dialedHost))
        let tls = TrinoTLSOptions(
            mode: mode,
            anchorCertificate: TLSTestFixtures.der(TLSTestFixtures.serverNameCACertificate),
            serverName: serverName
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: ServerTrustProtectionSpace(trust: trust, host: dialedHost),
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: IgnoringChallengeSender()
        )
        return TrinoTLSChallengeHandler(tls: tls).answer(challenge)
    }

    @Test("Verify Identity through a tunnel refuses a certificate that names only the loopback forward")
    func fullRefusesTheForwardsName() throws {
        let answer = try handlerAnswer(leaf: TLSTestFixtures.loopbackServerCertificate, mode: .full, serverName: "db.example.com")
        #expect(answer.disposition == .cancelAuthenticationChallenge)
        #expect(answer.refusal?.kind == .hostnameMismatch)
    }

    @Test("Verify Identity through a tunnel accepts the certificate that names the server behind it")
    func fullAcceptsTheServersName() throws {
        let answer = try handlerAnswer(leaf: TLSTestFixtures.databaseServerCertificate, mode: .full, serverName: "db.example.com")
        #expect(answer.disposition == .useCredential)
        #expect(answer.refusal == nil)
    }

    @Test("Verify CA through a tunnel checks the chain and not the name")
    func caOnlyIgnoresTheServerName() throws {
        let answer = try handlerAnswer(leaf: TLSTestFixtures.loopbackServerCertificate, mode: .caOnly, serverName: "db.example.com")
        #expect(answer.disposition == .useCredential)
        #expect(answer.refusal == nil)
    }

    @Test("A direct dial with no server name is checked against the host it dialed")
    func directDialChecksTheDialedHost() throws {
        let matching = try handlerAnswer(
            leaf: TLSTestFixtures.databaseServerCertificate,
            dialedHost: "db.example.com",
            mode: .full,
            serverName: nil
        )
        #expect(matching.disposition == .useCredential)

        let mismatched = try handlerAnswer(
            leaf: TLSTestFixtures.loopbackServerCertificate,
            dialedHost: "db.example.com",
            mode: .full,
            serverName: nil
        )
        #expect(mismatched.refusal?.kind == .hostnameMismatch)
    }
}
