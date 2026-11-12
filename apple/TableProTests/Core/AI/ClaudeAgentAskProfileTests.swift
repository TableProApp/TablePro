//
//  ClaudeAgentAskProfileTests.swift
//  TableProTests
//

import Foundation
import TableProMCP
import TableProMCPTestSupport
import Testing

@testable import TablePro

private final class AskProfileCredentials: MCPTokenCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?

    init(stored: Data? = Data("[]".utf8)) {
        self.stored = stored
    }

    func read() -> MCPTokenBlob {
        lock.withLock { stored.map(MCPTokenBlob.found) ?? .missing }
    }

    @discardableResult
    func write(_ data: Data) -> Bool {
        lock.withLock { stored = data }
        return true
    }

    func delete() {
        lock.withLock { stored = nil }
    }
}

struct ClaudeAgentAskProfileTests {
    private static let askToolNames: Set<String> = [
        "list_connections",
        "get_connection_status",
        "list_databases",
        "list_schemas",
        "list_tables",
        "describe_table",
        "get_table_ddl"
    ]

    private let connectionId = UUID()

    private func mint(
        in store: MCPTokenStore,
        toolProfile: MCPToolProfile?
    ) async throws -> (token: MCPAuthToken, plaintext: String) {
        try await store.generate(
            name: "__claude_agent__",
            permissions: .readOnly,
            connectionAccess: .limited([connectionId]),
            expiresAt: Date.now.addingTimeInterval(900),
            isBridgeCredential: false,
            isClaudeAgentCredential: true,
            extraScopes: [],
            toolProfile: toolProfile
        )
    }

    private func authenticate(_ plaintext: String, against store: MCPTokenStore) async -> MCPAuthDecision {
        let clock = MCPTestClock()
        let authenticator = MCPBearerTokenAuthenticator(
            tokenStore: store,
            rateLimiter: MCPRateLimiter(clock: clock),
            clock: clock
        )
        return await authenticator.authenticate(authorizationHeader: "Bearer \(plaintext)", clientAddress: .loopback)
    }

    private func principal(presenting plaintext: String, to store: MCPTokenStore) async throws -> MCPPrincipal {
        let decision = await authenticate(plaintext, against: store)
        guard case .allow(let principal) = decision else {
            Issue.record("Expected allow, got \(decision)")
            throw CancellationError()
        }
        return principal
    }

    private func storedEntries(_ tokens: [MCPAuthToken]) throws -> [[String: Any]] {
        let data = try MCPTokenStore.encodeStored(tokens: tokens, undecoded: [])
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            Issue.record("The stored tokens are not a JSON list")
            throw CancellationError()
        }
        return entries
    }

    private func reloaded(entries: [[String: Any]]) throws -> MCPTokenStore {
        let data = try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
        return MCPTokenStore(credentialStore: AskProfileCredentials(stored: data))
    }

    @Test("Ask mode gets the schema lookup profile, Edit and Agent keep today's token")
    func profileFollowsTheChatMode() {
        #expect(ClaudeAgentMCPBridge.toolProfile(for: .ask) == .schemaLookup)
        #expect(ClaudeAgentMCPBridge.toolProfile(for: .edit) == nil)
        #expect(ClaudeAgentMCPBridge.toolProfile(for: .agent) == nil)
    }

    @Test("The profile's tools are the seven documented Ask tools")
    @MainActor
    func profileMatchesTheDocumentedAskSet() throws {
        let chatAskTools = Set(ChatToolBootstrap.makeTools().filter { $0.mode.isAllowed(in: .ask) }.map { $0.name })

        #expect(MCPToolProfile.schemaLookup.toolNames == Self.askToolNames)
        #expect(MCPToolProfile.schemaLookup.toolNames == chatAskTools)
        #expect(MCPToolProfile.schemaLookup.scopes == [.toolsRead])
        for name in MCPToolProfile.schemaLookup.toolNames {
            let tool = try #require(MCPToolRegistry.tool(named: name), "\(name) is not an MCP tool")
            #expect(type(of: tool).requiredScopes.isSubset(of: MCPToolProfile.schemaLookup.scopes))
        }
    }

    @Test("An Ask token authenticates as tools:read only, held to the seven tools")
    func askTokenIsNarrowed() async throws {
        let store = MCPTokenStore(credentialStore: AskProfileCredentials())
        let minted = try await mint(in: store, toolProfile: .schemaLookup)

        let principal = try await principal(presenting: minted.plaintext, to: store)

        #expect(principal.scopes == [.toolsRead])
        #expect(!principal.has(.resourcesRead))
        #expect(principal.toolAllowlist == Self.askToolNames)
        #expect(principal.allowsTool("describe_table"))
        #expect(!principal.allowsTool("execute_query"))
        #expect(!principal.allowsTool("browse_table"))
        #expect(!principal.allowsTool("search_query_history"))
    }

    @Test("A token minted without a profile, as pairing and Settings mint, keeps its tier and every tool")
    func mintWithoutProfileIsUnchanged() async throws {
        let store = MCPTokenStore(credentialStore: AskProfileCredentials())
        let minted = try await store.generate(
            name: "Raycast",
            permissions: .readOnly,
            connectionAccess: .all,
            expiresAt: nil,
            isBridgeCredential: false,
            isClaudeAgentCredential: false,
            extraScopes: []
        )

        let principal = try await principal(presenting: minted.plaintext, to: store)

        #expect(minted.token.toolProfile == nil)
        #expect(principal.scopes == MCPScope.readOnlySet)
        #expect(principal.toolAllowlist == nil)
    }

    @Test("The profile survives a save and reload, and a token without one writes no key")
    func profileRoundTrips() async throws {
        let store = MCPTokenStore(credentialStore: AskProfileCredentials())
        let ask = try await mint(in: store, toolProfile: .schemaLookup).token
        let edit = try await mint(in: store, toolProfile: nil).token

        let data = try MCPTokenStore.encodeStored(tokens: [ask, edit], undecoded: [])
        let decoded = MCPTokenStore.decodeStored(data)
        let profiles = decoded.tokens.map { $0.toolProfile }
        let mentions = String(bytes: data, encoding: .utf8)?.components(separatedBy: "toolProfile").count

        #expect(profiles == [.schemaLookup, nil])
        #expect(decoded.undecoded.isEmpty)
        #expect(mentions == 2)
        #expect(decoded.tokens.first?.scopes == [.toolsRead])
    }

    @Test("A stored profile this build cannot read keeps the entry undecoded and its token stops working")
    func unknownProfileFailsClosed() async throws {
        let original = MCPTokenStore(credentialStore: AskProfileCredentials())
        let minted = try await mint(in: original, toolProfile: .schemaLookup)

        let damagedValues: [Any] = ["everything", "", NSNull(), 7]
        for damaged in damagedValues {
            var entries = try storedEntries([minted.token])
            entries[0]["toolProfile"] = damaged
            let data = try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])

            let decoded = MCPTokenStore.decodeStored(data)
            #expect(decoded.tokens.isEmpty, "a damaged profile \(damaged) must not decode")
            #expect(decoded.undecoded.count == 1)

            let store = try reloaded(entries: entries)
            await store.loadFromDisk()
            let decision = await authenticate(minted.plaintext, against: store)
            guard case .deny = decision else {
                Issue.record("A token with a damaged profile \(damaged) authenticated: \(decision)")
                continue
            }
        }
    }

    @Test("An Ask token is refused resources/read and prompts/get at the dispatcher")
    func askTokenIsRefusedResourcesAndPrompts() async throws {
        let store = MCPTokenStore(credentialStore: AskProfileCredentials())
        let minted = try await mint(in: store, toolProfile: .schemaLookup)
        let principal = try await principal(presenting: minted.plaintext, to: store)
        let services = MCPProtocolHandlerTestSupport.makeToolServices()

        for method in [ResourcesReadHandler.method, PromptsGetHandler.method, ResourcesListHandler.method] {
            let dispatcher = MCPProtocolTestSupport.makeDispatcher(handlers: [
                ResourcesReadHandler(services: services),
                ResourcesListHandler(services: services),
                PromptsGetHandler(services: services)
            ])
            let (exchange, sink) = MCPProtocolTestSupport.makeExchange(
                message: MCPProtocolTestSupport.makeModernRequest(
                    method: method,
                    payload: ["uri": .string("tablepro://connections/\(connectionId.uuidString)/history")]
                ),
                principal: principal
            )
            await dispatcher.dispatch(exchange)
            await sink.waitForCompletion()

            let errorValue = try await sink.errorEnvelope()
            let error = try #require(errorValue, "\(method) answered an Ask token")
            #expect(error.code == JsonRpcErrorCode.forbidden)
        }
    }
}
