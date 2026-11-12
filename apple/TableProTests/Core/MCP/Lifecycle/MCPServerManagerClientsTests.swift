import Combine
import Foundation
import TableProMCP
import TableProTestSupport
import Testing

@testable import TablePro

@MainActor
@Suite(.serialized)
struct MCPServerManagerClientsTests {
    private struct Running {
        let manager: MCPServerManager
        let composition: MCPServerComposition
        let bridgeToken: String
    }

    private let directory: URL

    init() throws {
        // Short, so the socket fits in sun_path inside the folder itself.
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mcp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func withRunningServer(_ body: (Running) async throws -> Void) async throws {
        let manager = MCPServerManager(handshake: MCPHandshakeFile(directory: directory), isEnabled: { true })
        try await manager.start(port: 0)
        do {
            try await waitUntil {
                await MainActor.run {
                    if case .failed = manager.state { return true }
                    return manager.isRunning
                }
            }
            try #require(manager.isRunning, "The MCP server did not start: \(manager.state)")
            let composition = try #require(manager.composition)
            let data = try Data(contentsOf: MCPHandshakeLocation.file(in: directory))
            let handshake = try MCPHandshakeCoding.decoder().decode(MCPHandshakePayload.self, from: data)
            try await body(Running(manager: manager, composition: composition, bridgeToken: handshake.token))
        } catch {
            await manager.stop()
            throw error
        }
        await manager.stop()
    }

    private func principal(presenting token: String, from address: MCPClientAddress, to running: Running) async throws -> MCPPrincipal {
        let decision = await running.composition.authenticator.authenticate(
            authorizationHeader: "Bearer \(token)",
            clientAddress: address
        )
        guard case .allow(let principal) = decision else {
            Issue.record("Expected the token to be accepted, got \(decision)")
            throw CancellationError()
        }
        return principal
    }

    private func record(_ clientName: String, as principal: MCPPrincipal, from address: MCPClientAddress, in running: Running) async {
        let meta = MCPRequestMeta(
            protocolVersion: .latest,
            clientInfo: MCPImplementation(name: clientName, version: "1"),
            clientCapabilities: .none,
            progressToken: nil
        )
        await running.composition.activityLedger.record(meta: meta, principal: principal, address: address, at: Date())
    }

    @Test("Disconnect on a stdio client forgets that client only and leaves the shared bridge credential working")
    func stdioDisconnectKeepsTheBridgeCredential() async throws {
        try await withRunningServer { running in
            let bridge = try await principal(presenting: running.bridgeToken, from: .localSocket, to: running)
            await record("claude-ai", as: bridge, from: .localSocket, in: running)
            await record("cursor-vscode", as: bridge, from: .localSocket, in: running)
            await running.manager.refreshClients()

            let clients = running.manager.connectedClients
            #expect(clients.count == 2)
            #expect(clients.allSatisfy { $0.transport == .stdioBridge })
            let claude = try #require(clients.first { $0.clientName == "claude-ai" })

            #expect(await running.manager.disconnectClient(claude.id))

            #expect(running.manager.connectedClients.map { $0.clientName } == ["cursor-vscode"])
            #expect(await running.manager.tokenStore?.validate(bearerToken: running.bridgeToken) != nil)
            _ = try await principal(presenting: running.bridgeToken, from: .localSocket, to: running)
        }
    }

    @Test("Disconnect on a client with its own token revokes that token")
    func tokenDisconnectRevokesTheToken() async throws {
        try await withRunningServer { running in
            let store = try #require(running.manager.tokenStore)
            let minted = try await store.generate(
                name: "Raycast",
                permissions: .readOnly,
                connectionAccess: .all,
                expiresAt: nil,
                isBridgeCredential: false,
                isClaudeAgentCredential: false,
                extraScopes: []
            )
            let paired = try await principal(presenting: minted.plaintext, from: .loopback, to: running)
            await record("raycast", as: paired, from: .loopback, in: running)
            await running.manager.refreshClients()
            let row = try #require(running.manager.connectedClients.first)
            #expect(row.transport == .http)

            #expect(await running.manager.disconnectClient(row.id))

            #expect(running.manager.connectedClients.isEmpty)
            #expect(await store.validate(bearerToken: minted.plaintext) == nil)
            #expect(await running.manager.tokenStore?.validate(bearerToken: running.bridgeToken) != nil)
            await store.delete(tokenId: minted.token.id)
        }
    }

    @Test("A refresh that finds nothing new does not publish the client list again")
    func unchangedClientsAreNotRepublished() async throws {
        try await withRunningServer { running in
            let counter = PublishCounter()
            let subscription = running.manager.$connectedClients.dropFirst().sink { _ in counter.count += 1 }
            defer { subscription.cancel() }

            let bridge = try await principal(presenting: running.bridgeToken, from: .localSocket, to: running)
            await record("Zed", as: bridge, from: .localSocket, in: running)
            await running.manager.refreshClients()
            let afterNewClient = counter.count
            #expect(afterNewClient >= 1)

            await running.manager.refreshClients()
            await running.manager.refreshClients()

            #expect(counter.count == afterNewClient)
        }
    }

    @Test("Revoking with no server running reports that nothing was revoked")
    func revokeWithoutAStoreFails() async {
        let manager = MCPServerManager(handshake: MCPHandshakeFile(directory: directory), isEnabled: { false })

        #expect(await manager.revokeToken(id: UUID()) == false)
    }

    @Test("The window names TablePro's own clients and tokens, not their raw ids")
    func ownClientsReadAsTablePro() {
        #expect(IntegrationsFormatting.displayTokenName(MCPTokenStore.claudeAgentTokenName) == AIProviderType.claudeAgent.displayName)
        #expect(IntegrationsFormatting.displayTokenName("Raycast") == "Raycast")

        let command = Self.snapshot(clientName: CLIClientIdentity.title, clientInfoName: CLIClientIdentity.name)
        #expect(IntegrationsFormatting.displayClientName(command) == String(localized: "tablepro command"))
        let cursor = Self.snapshot(clientName: "Cursor", clientInfoName: "cursor-vscode")
        #expect(IntegrationsFormatting.displayClientName(cursor) == "Cursor")
    }

    private static func snapshot(clientName: String, clientInfoName: String) -> MCPServerManager.SessionSnapshot {
        MCPServerManager.SessionSnapshot(
            id: clientInfoName,
            clientName: clientName,
            clientInfoName: clientInfoName,
            clientVersion: "1",
            connectedSince: .distantPast,
            lastActivityAt: .distantPast,
            tokenName: nil,
            remoteAddress: nil,
            transport: .http
        )
    }
}

private final class PublishCounter {
    var count = 0
}
