import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("MCP HTTP Server Transport Pairing", .serialized)
struct MCPHttpServerTransportPairingTests {
    private static let exchangePath = "/v1/integrations/exchange"

    private func uniqueVerifier() -> String {
        let raw = UUID().uuidString + UUID().uuidString
        return String(raw.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(64))
    }

    private func uniqueCode() -> String {
        "test-code-\(UUID().uuidString)"
    }

    private func store() async -> PairingExchangeStore {
        await MainActor.run { MCPPairingService.shared.store }
    }

    private func insertPairingCode(
        code: String,
        plaintextToken: String,
        verifier: String,
        expiresIn: TimeInterval
    ) async throws {
        try await store().insert(
            code: code,
            record: PairingExchangeRecord(
                plaintextToken: plaintextToken,
                tokenId: UUID(),
                challenge: PairingExchangeStore.sha256Base64Url(of: verifier),
                expiresAt: Date.now.addingTimeInterval(expiresIn)
            )
        )
    }

    private func discard(code: String) async {
        await store().discard(code: code)
    }

    private func exchangeRequest(port: UInt16, body: Data?) -> Data {
        MCPTransportTestRequests.raw(
            method: "POST",
            path: Self.exchangePath,
            port: port,
            headers: [("Content-Type", "application/json")],
            body: body
        )
    }

    private func post(port: UInt16, body: Data?) async throws -> RawHttpTestResponse {
        let client = RawHttpTestClient(port: port)
        try await client.connect()
        defer { Task { await client.close() } }
        try await client.send(exchangeRequest(port: port, body: body))
        return try await client.readResponse()
    }

    @Test("An empty body is refused as invalid JSON")
    func emptyBodyIsBadRequest() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let response = try await post(port: port, body: Data())

            #expect(response.statusCode == 400)
            #expect(try response.plainJsonField("error") == "Invalid JSON body")
        }
    }

    @Test("Malformed JSON is refused as invalid JSON")
    func malformedJsonIsBadRequest() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let response = try await post(port: port, body: Data("{not-json".utf8))

            #expect(response.statusCode == 400)
            #expect(try response.plainJsonField("error") == "Invalid JSON body")
        }
    }

    @Test("A blank code or verifier is refused before the store is touched")
    func blankFieldsAreBadRequest() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let bodies = [
                Data(#"{"code":"","code_verifier":"verifier"}"#.utf8),
                Data(#"{"code":"abc","code_verifier":""}"#.utf8)
            ]
            for body in bodies {
                let response = try await post(port: port, body: body)
                #expect(response.statusCode == 400)
                #expect(try response.plainJsonField("error") == "Missing code or code_verifier")
            }
        }
    }

    @Test("A field beyond the size cap is refused")
    func oversizedFieldIsBadRequest() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let payload = ["code": String(repeating: "a", count: 2_048), "code_verifier": uniqueVerifier()]
            let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let response = try await post(port: port, body: body)

            #expect(response.statusCode == 400)
            #expect(try response.plainJsonField("error") == "Field exceeds size limit")
        }
    }

    @Test("A valid code and verifier exchange for the paired token")
    func successfulExchangeReturnsTheToken() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let code = uniqueCode()
            let verifier = uniqueVerifier()
            let plaintext = "tp_test-token-\(UUID().uuidString)"
            try await insertPairingCode(
                code: code,
                plaintextToken: plaintext,
                verifier: verifier,
                expiresIn: 60
            )

            let payload = ["code": code, "code_verifier": verifier]
            let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let response = try await post(port: port, body: body)

            #expect(response.statusCode == 200)
            #expect(try response.plainJsonField("token") == plaintext)

            let stillPending = await store().contains(code: code)
            #expect(!stillPending, "a pairing code is single-use")
        }
    }

    @Test("An unknown code answers 404")
    func unknownCodeIsNotFound() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let payload = ["code": uniqueCode(), "code_verifier": uniqueVerifier()]
            let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let response = try await post(port: port, body: body)

            #expect(response.statusCode == 404)
            #expect(try response.plainJsonField("error") == "Pairing code not found")
        }
    }

    @Test("A verifier that does not match the challenge answers 403 and burns the code")
    func mismatchedVerifierIsForbidden() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let code = uniqueCode()
            try await insertPairingCode(
                code: code,
                plaintextToken: "tp_test",
                verifier: uniqueVerifier(),
                expiresIn: 60
            )
            defer { Task { await discard(code: code) } }

            let payload = ["code": code, "code_verifier": uniqueVerifier()]
            let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let response = try await post(port: port, body: body)

            #expect(response.statusCode == 403)
            #expect(try response.plainJsonField("error") == "Challenge mismatch")

            let stillPending = await store().contains(code: code)
            #expect(!stillPending, "a failed verification burns the code")
        }
    }

    @Test("An expired code is unredeemable")
    func expiredCodeIsUnredeemable() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let code = uniqueCode()
            let verifier = uniqueVerifier()
            try await insertPairingCode(
                code: code,
                plaintextToken: "tp_test",
                verifier: verifier,
                expiresIn: -60
            )
            defer { Task { await discard(code: code) } }

            let payload = ["code": code, "code_verifier": verifier]
            let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let response = try await post(port: port, body: body)

            #expect(response.statusCode == 410 || response.statusCode == 404)
            let message = try response.plainJsonField("error")
            #expect(message == "Pairing code expired" || message == "Pairing code not found")
        }
    }

    @Test("The exchange endpoint accepts POST only")
    func exchangeEndpointIsPostOnly() async throws {
        try await MCPTransportTestHarness.withServer { port in
            for method in ["GET", "DELETE"] {
                let client = RawHttpTestClient(port: port)
                try await client.connect()
                defer { Task { await client.close() } }
                try await client.send(
                    MCPTransportTestRequests.raw(
                        method: method,
                        path: Self.exchangePath,
                        port: port,
                        body: nil,
                        includeContentLength: false
                    )
                )
                let response = try await client.readResponse()
                #expect(response.statusCode == 405, "\(method) on the exchange endpoint must be 405")
                #expect(response.header("Allow")?.contains("POST") == true)
            }
        }
    }

    @Test("The exchange endpoint refuses a non-loopback Host")
    func exchangeEndpointRefusesRemoteHost() async throws {
        try await MCPTransportTestHarness.withServer { port in
            let client = RawHttpTestClient(port: port)
            try await client.connect()
            defer { Task { await client.close() } }
            try await client.send(
                MCPTransportTestRequests.raw(
                    method: "POST",
                    path: Self.exchangePath,
                    port: port,
                    host: "attacker.test",
                    headers: [("Content-Type", "application/json")],
                    body: Data("{}".utf8)
                )
            )
            let response = try await client.readResponse()

            #expect(response.statusCode == 403)
            #expect(try response.plainJsonField("error") == "forbidden_host")
        }
    }
}
