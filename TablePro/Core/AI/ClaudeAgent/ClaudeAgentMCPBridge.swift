//
//  ClaudeAgentMCPBridge.swift
//  TablePro
//

import Foundation
import os

struct ClaudeAgentToolGrant: Sendable, Equatable {
    let configPath: String
    let tokenId: UUID
}

protocol ClaudeAgentMCPBridging: Sendable {
    func makeGrant() async -> ClaudeAgentToolGrant?
    func release(_ grant: ClaudeAgentToolGrant?) async
}

struct ClaudeAgentMCPBridge: ClaudeAgentMCPBridging {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ClaudeAgentMCPBridge")
    private static let tokenName = "__claude_agent__"
    private static let tokenLifetime: TimeInterval = 15 * 60

    private let permissions: TokenPermissions
    private let connectionAccess: ConnectionAccess

    init(permissions: TokenPermissions = .readOnly, connectionAccess: ConnectionAccess = .all) {
        self.permissions = permissions
        self.connectionAccess = connectionAccess
    }

    func makeGrant() async -> ClaudeAgentToolGrant? {
        guard let endpoint = await Self.resolveEndpoint() else { return nil }
        guard let tokenStore = await MCPServerManager.shared.tokenStore else { return nil }

        guard let generated = try? await tokenStore.generate(
            name: Self.tokenName,
            permissions: permissions,
            connectionAccess: connectionAccess,
            expiresAt: Date.now.addingTimeInterval(Self.tokenLifetime)
        ) else { return nil }

        guard let configPath = Self.writeConfig(endpoint: endpoint, token: generated.plaintext) else {
            await tokenStore.delete(tokenId: generated.token.id)
            return nil
        }

        Self.logger.debug("Issued Claude Agent MCP grant")
        return ClaudeAgentToolGrant(configPath: configPath, tokenId: generated.token.id)
    }

    func release(_ grant: ClaudeAgentToolGrant?) async {
        guard let grant else { return }
        try? FileManager.default.removeItem(atPath: grant.configPath)
        guard let tokenStore = await MCPServerManager.shared.tokenStore else { return }
        await tokenStore.delete(tokenId: grant.tokenId)
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
            logger.error("Failed to write MCP config: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
