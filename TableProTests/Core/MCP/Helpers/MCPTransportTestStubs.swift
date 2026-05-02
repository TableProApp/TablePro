import Foundation
@testable import TablePro

actor StubAlwaysAllowAuthenticator: MCPAuthenticator {
    private let principal: MCPPrincipal

    init(scopes: Set<MCPScope> = [.toolsRead, .toolsWrite]) {
        self.principal = MCPPrincipal(
            tokenFingerprint: "stubtoken",
            scopes: scopes,
            metadata: MCPPrincipalMetadata(
                label: "stub",
                issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
                expiresAt: nil
            )
        )
    }

    func authenticate(
        authorizationHeader: String?,
        clientAddress: MCPClientAddress
    ) async -> MCPAuthDecision {
        .allow(principal)
    }
}

actor StubBearerAuthenticator: MCPAuthenticator {
    private let validToken: String
    private let principal: MCPPrincipal
    private var attemptsByAddress: [MCPClientAddress: Int] = [:]
    private let maxAttempts: Int

    init(validToken: String, maxAttempts: Int = 5) {
        self.validToken = validToken
        self.maxAttempts = maxAttempts
        self.principal = MCPPrincipal(
            tokenFingerprint: "fingerprint",
            scopes: [.toolsRead, .toolsWrite],
            metadata: MCPPrincipalMetadata(
                label: "test",
                issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
                expiresAt: nil
            )
        )
    }

    func authenticate(
        authorizationHeader: String?,
        clientAddress: MCPClientAddress
    ) async -> MCPAuthDecision {
        let attempts = attemptsByAddress[clientAddress] ?? 0
        if attempts >= maxAttempts {
            return .deny(.rateLimited(retryAfterSeconds: 30))
        }

        guard let raw = authorizationHeader, !raw.isEmpty else {
            attemptsByAddress[clientAddress] = attempts + 1
            return .deny(.unauthenticated(reason: "missing"))
        }

        let lowered = raw.lowercased()
        guard lowered.hasPrefix("bearer ") else {
            attemptsByAddress[clientAddress] = attempts + 1
            return .deny(.unauthenticated(reason: "bad scheme"))
        }
        let token = String(raw.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)

        if token == validToken {
            attemptsByAddress[clientAddress] = 0
            return .allow(principal)
        }

        attemptsByAddress[clientAddress] = attempts + 1
        return .deny(.tokenInvalid(reason: "bad token"))
    }
}

struct NullProgressSink: MCPProgressSink {
    func sendNotification(_ notification: JsonRpcNotification, toSession sessionId: MCPSessionId) async {}
}

actor StubExchangeConsumer {
    private var task: Task<Void, Never>?

    func start(
        transport: MCPHttpServerTransport,
        responder: @escaping @Sendable (MCPInboundExchange) async -> Void
    ) async {
        let stream = transport.exchanges
        task = Task {
            for await exchange in stream {
                await responder(exchange)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
