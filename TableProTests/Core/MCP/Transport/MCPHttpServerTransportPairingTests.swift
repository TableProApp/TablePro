import Foundation
@testable import TablePro
import Testing

@Suite("MCP HTTP Server Transport Pairing")
struct MCPHttpServerTransportPairingTests {
    private struct ExchangeError: Decodable {
        let error: String
    }

    private struct ExchangeResponse: Decodable {
        let token: String
    }

    private func makeTransport(
        authenticator: any MCPAuthenticator,
        clock: any MCPClock = MCPSystemClock()
    ) -> (MCPHttpServerTransport, MCPSessionStore) {
        let policy = MCPSessionPolicy(
            idleTimeout: .seconds(900),
            maxSessions: 16,
            cleanupInterval: .seconds(60)
        )
        let store = MCPSessionStore(policy: policy, clock: clock)
        let config = MCPHttpServerConfiguration.loopback(port: 0)
        let transport = MCPHttpServerTransport(
            configuration: config,
            sessionStore: store,
            authenticator: authenticator,
            clock: clock
        )
        return (transport, store)
    }

    private func startedTransport(
        authenticator: any MCPAuthenticator,
        clock: any MCPClock = MCPSystemClock()
    ) async throws -> (MCPHttpServerTransport, UInt16) {
        let (transport, _) = makeTransport(authenticator: authenticator, clock: clock)
        let stateStream = transport.listenerState
        let stateTask = Task<UInt16?, Never> {
            for await state in stateStream {
                if case .running(let port) = state {
                    return port
                }
                if case .failed = state {
                    return nil
                }
            }
            return nil
        }
        try await transport.start()
        guard let port = await stateTask.value, port != 0 else {
            await transport.stop()
            throw PairingTestError.serverDidNotStart
        }
        return (transport, port)
    }

    private func makeExchangeRequest(
        port: UInt16,
        body: Data?,
        contentType: String = "application/json"
    ) -> URLRequest {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/integrations/exchange") else {
            fatalError("Failed to construct test URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let body {
            request.httpBody = body
        }
        return request
    }

    private func insertPairingRecord(
        code: String,
        plaintextToken: String,
        challenge: String,
        expiresAt: Date
    ) async throws {
        let store = await MainActor.run { MCPPairingService.shared.store }
        try await store.insert(
            code: code,
            record: PairingExchangeRecord(
                plaintextToken: plaintextToken,
                challenge: challenge,
                expiresAt: expiresAt
            )
        )
    }

    private func clearPairingCode(_ code: String) async {
        let store = await MainActor.run { MCPPairingService.shared.store }
        _ = try? await store.consume(code: code, verifier: "__cleanup__")
    }

    private func uniqueCode() -> String {
        "test-code-\(UUID().uuidString)"
    }

    private func challenge(for verifier: String) -> String {
        PairingExchangeStore.sha256Base64Url(of: verifier)
    }

    @Test("Empty body returns 400 with invalid JSON body error")
    func emptyBodyReturnsBadRequest() async throws {
        let auth = StubAlwaysAllowAuthenticator()
        let (transport, port) = try await startedTransport(authenticator: auth)
        defer { Task { await transport.stop() } }

        let request = makeExchangeRequest(port: port, body: Data())
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 400)
        let decoded = try JSONDecoder().decode(ExchangeError.self, from: data)
        #expect(decoded.error == "Invalid JSON body")
    }

    @Test("Malformed JSON returns 400 with invalid JSON body error")
    func malformedJsonReturnsBadRequest() async throws {
        let auth = StubAlwaysAllowAuthenticator()
        let (transport, port) = try await startedTransport(authenticator: auth)
        defer { Task { await transport.stop() } }

        let body = Data("{not-json".utf8)
        let request = makeExchangeRequest(port: port, body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 400)
        let decoded = try JSONDecoder().decode(ExchangeError.self, from: data)
        #expect(decoded.error == "Invalid JSON body")
    }

    @Test("Missing code returns 400 with missing code error")
    func missingCodeReturnsBadRequest() async throws {
        let auth = StubAlwaysAllowAuthenticator()
        let (transport, port) = try await startedTransport(authenticator: auth)
        defer { Task { await transport.stop() } }

        let body = Data(#"{"code":"","code_verifier":"verifier"}"#.utf8)
        let request = makeExchangeRequest(port: port, body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 400)
        let decoded = try JSONDecoder().decode(ExchangeError.self, from: data)
        #expect(decoded.error == "Missing code or code_verifier")
    }

    @Test("Missing code_verifier returns 400 with missing code error")
    func missingCodeVerifierReturnsBadRequest() async throws {
        let auth = StubAlwaysAllowAuthenticator()
        let (transport, port) = try await startedTransport(authenticator: auth)
        defer { Task { await transport.stop() } }

        let body = Data(#"{"code":"abc","code_verifier":""}"#.utf8)
        let request = makeExchangeRequest(port: port, body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 400)
        let decoded = try JSONDecoder().decode(ExchangeError.self, from: data)
        #expect(decoded.error == "Missing code or code_verifier")
    }

    @Test("Unknown code returns 404 with not-found error")
    func unknownCodeReturnsNotFound() async throws {
        let auth = StubAlwaysAllowAuthenticator()
        let (transport, port) = try await startedTransport(authenticator: auth)
        defer { Task { await transport.stop() } }

        let synthetic = "synthetic-\(UUID().uuidString)"
        let body = Data(#"{"code":"\#(synthetic)","code_verifier":"any-verifier"}"#.utf8)
        let request = makeExchangeRequest(port: port, body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 404)
        let decoded = try JSONDecoder().decode(ExchangeError.self, from: data)
        #expect(decoded.error == "Pairing code not found")
    }

    @Test("Successful exchange returns 200 with token in body")
    func successfulExchangeReturnsToken() async throws {
        let auth = StubAlwaysAllowAuthenticator()
        let (transport, port) = try await startedTransport(authenticator: auth)
        defer { Task { await transport.stop() } }

        let code = uniqueCode()
        let verifier = "verifier-\(UUID().uuidString)"
        let plaintext = "tp_test-token-\(UUID().uuidString)"
        try await insertPairingRecord(
            code: code,
            plaintextToken: plaintext,
            challenge: challenge(for: verifier),
            expiresAt: Date.now.addingTimeInterval(60)
        )
        defer { Task { await clearPairingCode(code) } }

        let payload = ["code": code, "code_verifier": verifier]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])

        let request = makeExchangeRequest(port: port, body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 200)
        let decoded = try JSONDecoder().decode(ExchangeResponse.self, from: data)
        #expect(decoded.token == plaintext)
    }

    @Test("Mismatched verifier returns 403 with challenge mismatch error")
    func mismatchedVerifierReturnsForbidden() async throws {
        let auth = StubAlwaysAllowAuthenticator()
        let (transport, port) = try await startedTransport(authenticator: auth)
        defer { Task { await transport.stop() } }

        let code = uniqueCode()
        let realVerifier = "real-verifier-\(UUID().uuidString)"
        try await insertPairingRecord(
            code: code,
            plaintextToken: "tp_test",
            challenge: challenge(for: realVerifier),
            expiresAt: Date.now.addingTimeInterval(60)
        )
        defer { Task { await clearPairingCode(code) } }

        let payload = ["code": code, "code_verifier": "wrong-verifier"]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])

        let request = makeExchangeRequest(port: port, body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 403)
        let decoded = try JSONDecoder().decode(ExchangeError.self, from: data)
        #expect(decoded.error == "Challenge mismatch")
    }

    @Test("Expired pairing code is unredeemable")
    func expiredCodeIsUnredeemable() async throws {
        let auth = StubAlwaysAllowAuthenticator()
        let (transport, port) = try await startedTransport(authenticator: auth)
        defer { Task { await transport.stop() } }

        let code = uniqueCode()
        let verifier = "verifier-\(UUID().uuidString)"
        try await insertPairingRecord(
            code: code,
            plaintextToken: "tp_test",
            challenge: challenge(for: verifier),
            expiresAt: Date.now.addingTimeInterval(-60)
        )
        defer { Task { await clearPairingCode(code) } }

        let payload = ["code": code, "code_verifier": verifier]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])

        let request = makeExchangeRequest(port: port, body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 410 || http.statusCode == 404)
        let decoded = try JSONDecoder().decode(ExchangeError.self, from: data)
        #expect(decoded.error == "Pairing code expired" || decoded.error == "Pairing code not found")
    }
}

private enum PairingTestError: Error {
    case serverDidNotStart
}
