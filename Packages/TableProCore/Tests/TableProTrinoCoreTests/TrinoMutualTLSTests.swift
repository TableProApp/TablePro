import Foundation
import Network
import Security
import TableProTLSClientIdentity
import TableProTLSTestFixtures
@testable import TableProTrinoCore
import Testing

private final class MutualTLSServerState: @unchecked Sendable {
    private let lock = NSLock()
    private var presented: [String] = []
    private var ready = false

    var isReady: Bool {
        lock.withLock { ready }
    }

    var presentedCommonNames: [String] {
        lock.withLock { presented }
    }

    func markReady() {
        lock.withLock { ready = true }
    }

    func record(leafOf trust: SecTrust) {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return }
        var name: CFString?
        SecCertificateCopyCommonName(leaf, &name)
        lock.withLock { presented.append((name as String?) ?? "") }
    }
}

private final class MutualTLSServer: @unchecked Sendable {
    enum Version {
        case tls12
        case tls13
    }

    enum Reply {
        case complete
        case truncated

        var bytes: Data {
            switch self {
            case .complete:
                return Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8)
            case .truncated:
                return Data("HTTP/1.1 200 OK\r\nContent-Length: 4096\r\nConnection: close\r\n\r\n{\"id\"".utf8)
            }
        }
    }

    private let listener: NWListener
    private let state: MutualTLSServerState

    init(requiresClientCertificate: Bool, version: Version = .tls13, reply: Reply = .complete) throws {
        let serverCredential = try TLSClientIdentity.credential(
            certificate: TLSTestFixtures.data(TLSTestFixtures.serverCertificate),
            privateKey: TLSTestFixtures.data(TLSTestFixtures.serverKey)
        )
        let identity = try #require(serverCredential.identity.flatMap { sec_identity_create($0) })
        let authority = try #require(
            SecCertificateCreateWithData(nil, TLSTestFixtures.der(TLSTestFixtures.caCertificate) as CFData)
        )
        let state = MutualTLSServerState()
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_local_identity(options, identity)
        sec_protocol_options_set_peer_authentication_required(options, requiresClientCertificate)
        if version == .tls12 {
            sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        }
        sec_protocol_options_set_verify_block(options, { _, peerTrust, complete in
            let trust = sec_trust_copy_ref(peerTrust).takeRetainedValue()
            SecTrustSetAnchorCertificates(trust, [authority] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
            state.record(leafOf: trust)
            complete(SecTrustEvaluateWithError(trust, nil))
        }, DispatchQueue.global())
        let listener = try NWListener(using: NWParameters(tls: tls), on: .any)
        listener.stateUpdateHandler = { listenerState in
            guard case .ready = listenerState else { return }
            state.markReady()
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, error in
                guard error == nil else {
                    connection.cancel()
                    return
                }
                connection.send(content: reply.bytes, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        self.listener = listener
        self.state = state
        listener.start(queue: .global())
    }

    deinit {
        listener.cancel()
    }

    var presentedCommonNames: [String] {
        state.presentedCommonNames
    }

    func statementURL() async throws -> URL {
        for _ in 0 ..< 500 where !state.isReady {
            try await Task.sleep(for: .milliseconds(10))
        }
        let port = try #require(listener.port?.rawValue)
        return try #require(URL(string: "https://localhost:\(port)/v1/statement"))
    }
}

private final class CertificateRequestingProtocol: URLProtocol, URLAuthenticationChallengeSender, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let space = URLProtectionSpace(
            host: request.url?.host ?? "",
            port: 443,
            protocol: NSURLProtectionSpaceHTTPS,
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodClientCertificate
        )
        client?.urlProtocol(self, didReceive: URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: self
        ))
    }

    override func stopLoading() {}

    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {
        finish()
    }

    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {
        finish()
    }

    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {
        finish()
    }

    func cancel(_ challenge: URLAuthenticationChallenge) {
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }

    private func finish() {
        guard request.url?.path != "/drop" else {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: [:])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("Unauthorized".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class IgnoringChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

struct TrinoMutualTLSTests {
    private func clientCredential() throws -> URLCredential {
        try TLSClientIdentity.credential(
            certificate: TLSTestFixtures.data(TLSTestFixtures.clientCertificate),
            privateKey: TLSTestFixtures.data(TLSTestFixtures.clientKeyPKCS1)
        )
    }

    private func send(to server: MutualTLSServer, tls: TrinoTLSOptions) async throws -> TrinoHTTPResponse {
        let request = TrinoHTTPRequest(
            method: .post,
            url: try await server.statementURL(),
            headers: [:],
            body: Data("SELECT 1".utf8),
            timeoutSeconds: 10
        )
        return try await URLSessionTrinoTransport(tls: tls).send(request)
    }

    private func failure(to server: MutualTLSServer, tls: TrinoTLSOptions) async throws -> TrinoError? {
        do {
            _ = try await send(to: server, tls: tls)
            return nil
        } catch let error as TrinoError {
            return error
        }
    }

    @Test("A configured client certificate is presented, and the server sees the client it names")
    func certificateIsPresented() async throws {
        let server = try MutualTLSServer(requiresClientCertificate: true)

        let response = try await send(to: server, tls: TrinoTLSOptions(mode: .insecure, clientCredential: try clientCredential()))

        #expect(response.statusCode == 200)
        #expect(response.clientCertificateRequest == .answered)
        #expect(server.presentedCommonNames == ["probe-client"])
    }

    @Test("An EC client key held only in memory signs the handshake")
    func ellipticCurveCertificateIsPresented() async throws {
        let server = try MutualTLSServer(requiresClientCertificate: true)
        let credential = try TLSClientIdentity.credential(
            certificate: TLSTestFixtures.data(TLSTestFixtures.ecClientCertificate),
            privateKey: TLSTestFixtures.data(TLSTestFixtures.ecKeySEC1)
        )

        let response = try await send(to: server, tls: TrinoTLSOptions(mode: .insecure, clientCredential: credential))

        #expect(response.statusCode == 200)
        #expect(server.presentedCommonNames == ["probe-ec-client"])
    }

    @Test("A connection dropped after the server began answering is a dropped connection, not a rejected certificate")
    func droppedMidResponseIsTransport() async throws {
        for version in [MutualTLSServer.Version.tls12, .tls13] {
            let server = try MutualTLSServer(requiresClientCertificate: true, version: version, reply: .truncated)

            let error = try await failure(to: server, tls: TrinoTLSOptions(mode: .insecure, clientCredential: try clientCredential()))

            guard case .transport? = error else {
                Issue.record("Expected a dropped connection over \(version), got \(String(describing: error))")
                continue
            }
            #expect(server.presentedCommonNames == ["probe-client"])
        }
    }

    @Test("With no certificate, a TLS 1.2 server that requires one reports the missing certificate")
    func missingCertificateOverTLS12() async throws {
        let server = try MutualTLSServer(requiresClientCertificate: true, version: .tls12)

        let error = try await failure(to: server, tls: TrinoTLSOptions(mode: .insecure))

        guard case .tlsHandshakeFailed(.clientCertificateRequired, _)? = error else {
            Issue.record("Expected the missing client certificate, got \(String(describing: error))")
            return
        }
    }

    private func requestingTransport(_ tls: TrinoTLSOptions) -> URLSessionTrinoTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CertificateRequestingProtocol.self]
        return URLSessionTrinoTransport(tls: tls, configuration: configuration)
    }

    private func request(_ path: String) throws -> TrinoHTTPRequest {
        TrinoHTTPRequest(method: .post, url: try #require(URL(string: "https://trino.example.com\(path)")), headers: [:])
    }

    @Test("A server that only asks for a certificate, gets none and drops the connection reads as a dropped connection")
    func askedThenDroppedIsTransport() async throws {
        let transport = requestingTransport(TrinoTLSOptions(mode: .insecure))
        let dropping = try request("/drop")

        await #expect(throws: TrinoError.transport(URLError(.networkConnectionLost).localizedDescription)) {
            try await transport.send(dropping)
        }
    }

    @Test("A connection dropped after the certificate was sent reads as the certificate being rejected")
    func sentThenDroppedIsRejection() async throws {
        let transport = requestingTransport(TrinoTLSOptions(mode: .insecure, clientCredential: try clientCredential()))
        let dropping = try request("/drop")

        await #expect(throws: TrinoError.tlsHandshakeFailed(
            kind: .clientCertificateRejected,
            serverMessage: URLError(.networkConnectionLost).localizedDescription
        )) {
            try await transport.send(dropping)
        }
    }

    @Test("A coordinator that asked for a certificate and answered 401 is reported as missing the certificate")
    func unauthorizedAfterUnansweredRequest() async throws {
        let transport = requestingTransport(TrinoTLSOptions(mode: .insecure))

        let response = try await transport.send(try request("/unauthorized"))
        let client = TrinoStatementClient(
            transport: transport,
            config: TrinoClientConfig(host: "trino.example.com", port: 443, useTLS: true, user: "u"),
            session: TrinoSessionState()
        )

        #expect(response.statusCode == 401)
        #expect(response.clientCertificateRequest == .unanswered)
        await #expect(throws: TrinoError.tlsHandshakeFailed(kind: .clientCertificateRequired, serverMessage: "Unauthorized")) {
            try await client.execute("SELECT 1")
        }
    }

    @Test("A certificate from another CA is reported as rejected over TLS 1.2 and TLS 1.3")
    func foreignCertificateIsRejected() async throws {
        let rogue = try TLSClientIdentity.credential(
            certificate: TLSTestFixtures.data(TLSTestFixtures.rogueCertificate),
            privateKey: TLSTestFixtures.data(TLSTestFixtures.rogueKey)
        )
        for version in [MutualTLSServer.Version.tls12, .tls13] {
            let server = try MutualTLSServer(requiresClientCertificate: true, version: version)

            let error = try await failure(to: server, tls: TrinoTLSOptions(mode: .insecure, clientCredential: rogue))

            guard case .tlsHandshakeFailed(.clientCertificateRejected, _)? = error else {
                Issue.record("Expected a rejected client certificate, got \(String(describing: error))")
                continue
            }
            #expect(server.presentedCommonNames.contains("rogue"))
        }
    }

    @Test("Verify CA with no CA certificate refuses the server instead of checking it against the system roots")
    func verifyCAWithoutAnchorRefuses() async throws {
        let server = try MutualTLSServer(requiresClientCertificate: false)

        let error = try await failure(to: server, tls: TrinoTLSOptions(mode: .caOnly))

        #expect(error == .tlsHandshakeFailed(
            kind: .untrustedCertificate,
            serverMessage: "Verify CA has no CA certificate to check the server against."
        ))
    }

    @Test("A certificate challenge is answered with the configured credential, or recorded as unanswered")
    func clientCertificateChallenge() throws {
        let challenge = URLAuthenticationChallenge(
            protectionSpace: URLProtectionSpace(
                host: "trino.example.com",
                port: 443,
                protocol: NSURLProtectionSpaceHTTPS,
                realm: nil,
                authenticationMethod: NSURLAuthenticationMethodClientCertificate
            ),
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: IgnoringChallengeSender()
        )
        let credential = try clientCredential()

        let answered = TrinoTLSChallengeHandler(tls: TrinoTLSOptions(clientCredential: credential)).answer(challenge)
        let unanswered = TrinoTLSChallengeHandler(tls: TrinoTLSOptions()).answer(challenge)

        #expect(answered.disposition == .useCredential)
        #expect(answered.credential === credential)
        #expect(answered.clientCertificateRequest == .answered)
        #expect(unanswered.disposition == .performDefaultHandling)
        #expect(unanswered.credential == nil)
        #expect(unanswered.clientCertificateRequest == .unanswered)
    }
}
