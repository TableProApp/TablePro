import Foundation
@testable import TablePro
import TableProMCP
import TableProMCPTestSupport
import Testing

private final class MemoryTokenCredentials: MCPTokenCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data? = Data("[]".utf8)
    private var refusesWrites = false

    var failsWrites: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return refusesWrites
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            refusesWrites = newValue
        }
    }

    func read() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    @discardableResult
    func write(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !refusesWrites else { return false }
        stored = data
        return true
    }

    func delete() {
        lock.lock()
        defer { lock.unlock() }
        stored = nil
    }
}

private struct RevocationServer {
    let transport: MCPHttpServerTransport
    let socketPath: String
    let store: MCPTokenStore
    let credentials: MemoryTokenCredentials

    func revoke(form: String) async throws -> (status: Int, error: String?) {
        let request = MCPSocketHttpRequest(
            path: "/v1/integrations/revoke",
            headers: [("Content-Type", "application/x-www-form-urlencoded")],
            body: Data(form.utf8)
        )
        let response = try await MCPUnixSocketHttpClient.send(request, socketPath: socketPath, idleTimeout: .seconds(10))
        let body = try await response.collectBody()
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        return (response.status, object?["error"] as? String)
    }

    func mint(bridge: Bool = false) async throws -> (id: UUID, plaintext: String) {
        let minted = try await store.generate(
            name: bridge ? MCPTokenStore.stdioBridgeTokenName : "tablepro command",
            permissions: .readOnly,
            connectionAccess: .all,
            expiresAt: nil,
            isBridgeCredential: bridge,
            extraScopes: []
        )
        return (minted.token.id, minted.plaintext)
    }

    func isActive(_ id: UUID) async -> Bool? {
        await store.token(id: id)?.isActive
    }
}

private func withRevocationServer(body: (RevocationServer) async throws -> Void) async throws {
    let folder = try MCPTestSocketFolder.make()
    defer { try? FileManager.default.removeItem(at: folder) }
    let socketPath = MCPSocketLocation.primarySocket(in: folder).path
    let credentials = MemoryTokenCredentials()
    let store = MCPTokenStore(credentialStore: credentials)
    let transport = MCPHttpServerTransport(
        configuration: .loopback(port: 0, socketPath: socketPath),
        authenticator: StubAlwaysAllowAuthenticator(),
        pairingService: await MCPPairingService(),
        tokenRevoker: store
    )
    try await transport.start()
    do {
        try await body(RevocationServer(transport: transport, socketPath: socketPath, store: store, credentials: credentials))
    } catch {
        await MCPTransportTestHarness.stop(transport)
        throw error
    }
    await MCPTransportTestHarness.stop(transport)
}

struct MCPTokenRevocationRouteTests {
    @Test("A paired token presented over the socket is revoked, and presenting it again still answers 200")
    func revokesAPairedToken() async throws {
        try await withRevocationServer { server in
            let paired = try await server.mint()
            let other = try await server.mint()

            let first = try await server.revoke(form: "token=\(paired.plaintext)&token_type_hint=refresh_token")
            #expect(first.status == 200)
            #expect(await server.isActive(paired.id) == false)
            #expect(await server.store.validate(bearerToken: paired.plaintext)?.id == nil)
            #expect(await server.isActive(other.id) == true)

            let again = try await server.revoke(form: "token=\(paired.plaintext)")
            #expect(again.status == 200)
        }
    }

    @Test("A revocation the Keychain did not take answers 503 temporarily_unavailable, and a retry once it saves answers 200")
    func unsavedRevocationAnswers503() async throws {
        try await withRevocationServer { server in
            let paired = try await server.mint()

            server.credentials.failsWrites = true
            let unsaved = try await server.revoke(form: "token=\(paired.plaintext)")
            #expect(unsaved.status == 503)
            #expect(unsaved.error == "temporarily_unavailable")

            server.credentials.failsWrites = false
            let retried = try await server.revoke(form: "token=\(paired.plaintext)")
            #expect(retried.status == 200)
            #expect(retried.error == nil)
            #expect(await server.isActive(paired.id) == false)
        }
    }

    @Test("An unknown token answers 200 and revokes nothing")
    func unknownTokenAnswersOk() async throws {
        try await withRevocationServer { server in
            let paired = try await server.mint()

            let response = try await server.revoke(form: "token=tp_never-issued")

            #expect(response.status == 200)
            #expect(response.error == nil)
            #expect(await server.isActive(paired.id) == true)
        }
    }

    @Test("The shared bridge credential is refused as an unsupported token type and stays active")
    func refusesTheBridgeCredential() async throws {
        try await withRevocationServer { server in
            let bridge = try await server.mint(bridge: true)

            let response = try await server.revoke(form: "token=\(bridge.plaintext)")

            #expect(response.status == 400)
            #expect(response.error == "unsupported_token_type")
            #expect(await server.isActive(bridge.id) == true)
        }
    }

    @Test("A request without exactly one token is refused as invalid_request", arguments: [
        "",
        "token=",
        "token_type_hint=access_token",
        "token=tp_a&token=tp_b",
        "token=%zz"
    ])
    func missingTokenIsInvalidRequest(form: String) async throws {
        try await withRevocationServer { server in
            let response = try await server.revoke(form: form)

            #expect(response.status == 400)
            #expect(response.error == "invalid_request")
        }
    }

    @Test("Over the TCP port the route does not exist, and the token stays active")
    func tcpDoesNotServeTheRoute() async throws {
        try await withRevocationServer { server in
            let paired = try await server.mint()
            let port = try #require(await server.transport.listeningPort)
            let client = RawHttpTestClient(port: port)
            try await client.connect()
            defer { Task { await client.close() } }

            try await client.send(MCPTransportTestRequests.raw(
                path: "/v1/integrations/revoke",
                port: port,
                headers: [("Content-Type", "application/x-www-form-urlencoded")],
                body: Data("token=\(paired.plaintext)".utf8)
            ))
            let response = try await client.readResponse()

            #expect(response.statusCode == 404)
            #expect(await server.isActive(paired.id) == true)
        }
    }

    @Test("The form parser decodes the token and ignores other parameters")
    func formParserDecodesTheToken() {
        let token = MCPHttpRequestRouter.revocationToken(fromForm: Data("token_type_hint=x&token=tp%5Fab+c".utf8))
        #expect(token == "tp_ab c")
    }

    @Test("A token longer than the size cap is refused")
    func oversizedTokenIsRefused() {
        let long = String(repeating: "a", count: MCPHttpRequestRouter.maxRevocationTokenBytes + 1)
        #expect(MCPHttpRequestRouter.revocationToken(fromForm: Data("token=\(long)".utf8)) == nil)
    }
}
