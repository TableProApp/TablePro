import Foundation
import os
import TableProMCP

struct ClaudeAgentToolGrant: Sendable, Equatable {
    let configPath: String
    let tokenId: UUID
}

// A turn that was asked to use a connection stops with one of these rather than run without its tools.
enum ClaudeAgentToolGrantError: Error, LocalizedError, Equatable {
    case tokenNotSaved
    case tokenNotCreated
    case configNotWritten

    var errorDescription: String? {
        switch self {
        case .tokenNotSaved:
            String(localized: "Claude Agent can't use this connection: TablePro couldn't save its access token to the Keychain. Try again.")
        case .tokenNotCreated:
            String(localized: "Claude Agent can't use this connection: TablePro couldn't create its access token. Try again.")
        case .configNotWritten:
            String(localized: "Claude Agent can't use this connection: TablePro couldn't write its MCP settings file. Try again.")
        }
    }
}

protocol ClaudeAgentMCPBridging: Sendable {
    func makeGrant(connectionId: UUID?) async throws -> ClaudeAgentToolGrant?
    func release(_ grant: ClaudeAgentToolGrant?) async
}

struct ClaudeAgentMCPBridge: ClaudeAgentMCPBridging {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ClaudeAgentMCPBridge")
    private static let tokenLifetime: TimeInterval = 15 * 60

    private let permissions: TokenPermissions
    private let endpoint: @Sendable () async -> URL?
    private let tokenStore: @Sendable () async -> MCPTokenStore?

    init(
        permissions: TokenPermissions = .readOnly,
        endpoint: (@Sendable () async -> URL?)? = nil,
        tokenStore: (@Sendable () async -> MCPTokenStore?)? = nil
    ) {
        self.permissions = permissions
        self.endpoint = endpoint ?? { await ClaudeAgentMCPBridge.resolveEndpoint() }
        self.tokenStore = tokenStore ?? { await MCPServerManager.shared.tokenStore }
    }

    static func connectionAccess(for connectionId: UUID?) -> ConnectionAccess? {
        guard let connectionId else { return nil }
        return .limited([connectionId])
    }

    func makeGrant(connectionId: UUID?) async throws -> ClaudeAgentToolGrant? {
        guard let connectionAccess = Self.connectionAccess(for: connectionId) else {
            Self.logger.info("No connection attached; Claude Agent runs without database tools")
            return nil
        }
        guard let endpoint = await self.endpoint() else { return nil }
        guard let tokenStore = await self.tokenStore() else { return nil }

        let generated: (token: MCPAuthToken, plaintext: String)
        do {
            generated = try await tokenStore.generate(
                name: MCPTokenStore.claudeAgentTokenName,
                permissions: permissions,
                connectionAccess: connectionAccess,
                expiresAt: Date.now.addingTimeInterval(Self.tokenLifetime),
                isBridgeCredential: false,
                isClaudeAgentCredential: true,
                extraScopes: []
            )
        } catch {
            Self.logger.error("Claude Agent token was not issued: \(error.publicLogShape, privacy: .public)")
            switch error as? MCPTokenStoreError {
            case .notSaved?, .keychainUnavailable?:
                throw ClaudeAgentToolGrantError.tokenNotSaved
            case .storedTokensUnreadable?, .randomGenerationFailed?, nil:
                throw ClaudeAgentToolGrantError.tokenNotCreated
            }
        }

        guard let configPath = Self.writeConfig(endpoint: endpoint, token: generated.plaintext) else {
            await tokenStore.retire(tokenId: generated.token.id)
            throw ClaudeAgentToolGrantError.configNotWritten
        }

        Self.logger.debug("Issued Claude Agent MCP grant")
        return ClaudeAgentToolGrant(configPath: configPath, tokenId: generated.token.id)
    }

    func release(_ grant: ClaudeAgentToolGrant?) async {
        guard let grant else { return }
        try? FileManager.default.removeItem(atPath: grant.configPath)
        guard let tokenStore = await self.tokenStore() else { return }
        await tokenStore.retire(tokenId: grant.tokenId)
        Self.logger.debug("Released Claude Agent MCP grant")
    }

    @MainActor
    private static func resolveEndpoint() -> URL? {
        guard case .running(let port) = MCPServerManager.shared.state else {
            logger.info("MCP server is not running; Claude Agent runs without database tools")
            return nil
        }
        return URL(string: "http://127.0.0.1:\(port)/mcp")
    }

    static func configPayload(endpoint: URL, token: String) -> String? {
        let payload: [String: Any] = [
            "mcpServers": [
                ClaudeAgent.mcpServerName: [
                    "type": "http",
                    "url": endpoint.absoluteString,
                    "headers": ["Authorization": "Bearer \(token)"]
                ]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeConfig(endpoint: URL, token: String) -> String? {
        guard let payload = configPayload(endpoint: endpoint, token: token) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "tablepro-claude-mcp-\(UUID().uuidString).json")
        do {
            try payload.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            return url.path
        } catch {
            logger.error("Failed to write MCP config: \(error.publicLogShape, privacy: .public)")
            return nil
        }
    }
}
