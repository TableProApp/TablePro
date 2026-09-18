//
//  MCPToolTestHarness.swift
//  TableProTests
//

import Foundation
@testable import TablePro

actor ToolTestResponderSink: MCPResponderSink {
    private(set) var jsonPayloads: [Data] = []
    private(set) var sseFrames: [SseFrame] = []
    private(set) var streamOpened = false
    private(set) var connectionClosed = false

    func writeJson(_ data: Data, status: HttpStatus, extraHeaders: [(String, String)]) async {
        jsonPayloads.append(data)
    }

    func writeAccepted() async {}

    func beginSseStream() async {
        streamOpened = true
    }

    func writeSseFrame(_ frame: SseFrame) async {
        sseFrames.append(frame)
    }

    func closeConnection() async {
        connectionClosed = true
    }

    func isClosed() async -> Bool {
        connectionClosed
    }

    func notificationMethods() -> [String] {
        sseFrames.compactMap { frame in
            guard let data = frame.data.data(using: .utf8),
                  let message = try? JsonRpcCodec.decode(data),
                  case .notification(let notification) = message
            else {
                return nil
            }
            return notification.method
        }
    }
}

actor ToolTestQueryHistoryStore: QueryHistoryReading {
    private(set) var receivedFilters: [QueryHistoryFilter] = []
    private var entries: [QueryHistoryEntry]

    init(entries: [QueryHistoryEntry] = []) {
        self.entries = entries
    }

    func fetch(
        _ filter: QueryHistoryFilter,
        after cursor: QueryHistoryCursor?,
        limit: Int
    ) async -> QueryHistoryPage {
        receivedFilters.append(filter)
        let allowed = filter.allowedConnectionIds
        let matching = entries.filter { entry in
            guard let allowed else { return true }
            return allowed.contains(entry.connectionId)
        }
        return QueryHistoryPage(entries: Array(matching.prefix(limit)), nextCursor: nil)
    }

    func delete(id: UUID) async -> Bool { false }

    func clear(matching filter: QueryHistoryFilter) async -> Bool { false }

    func count(scope: QueryHistoryScope) async -> Int { entries.count }
}

enum MCPToolTestHarness {
    static let tokenId = UUID(uuidString: "0F2A6C41-1111-4222-8333-000000000001")

    static func principal(
        scopes: Set<MCPScope> = [.toolsRead, .toolsWrite],
        access: ConnectionAccess = .all,
        fingerprint: String = "tool-test-fp"
    ) -> MCPPrincipal {
        MCPPrincipal(
            tokenFingerprint: fingerprint,
            tokenId: tokenId,
            scopes: scopes,
            connectionAccess: access,
            metadata: MCPPrincipalMetadata(
                label: "tool tests",
                issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
                expiresAt: nil
            )
        )
    }

    static func elicitingClient(modes: Set<String> = ["form"]) -> MCPClientCapabilities {
        MCPClientCapabilities(
            supportsElicitation: true,
            elicitationModes: modes,
            raw: .object([
                "elicitation": .object(["modes": .array(modes.sorted().map { .string($0) })])
            ])
        )
    }

    static func meta(
        protocolVersion: MCPProtocolVersion = .latest,
        clientCapabilities: MCPClientCapabilities = .none,
        progressToken: MCPProgressToken? = nil
    ) -> MCPRequestMeta {
        MCPRequestMeta(
            protocolVersion: protocolVersion,
            clientInfo: MCPImplementation(name: "tool-tests", version: "1.0"),
            clientCapabilities: clientCapabilities,
            progressToken: progressToken
        )
    }

    static func context(
        params: JsonValue? = nil,
        principal: MCPPrincipal? = nil,
        clientCapabilities: MCPClientCapabilities = .none,
        progressToken: MCPProgressToken? = nil,
        cancellation: MCPCancellationToken = MCPCancellationToken(),
        sink: ToolTestResponderSink = ToolTestResponderSink(),
        requestId: JsonRpcId = .number(1)
    ) -> MCPRequestContext {
        let responder = MCPResponder(sink: sink, requestId: requestId)
        return MCPRequestContext(
            requestId: requestId,
            params: params,
            meta: meta(clientCapabilities: clientCapabilities, progressToken: progressToken),
            principal: principal ?? self.principal(),
            responder: responder,
            progress: MCPProgressEmitter(progressToken: progressToken, responder: responder),
            cancellation: cancellation,
            clock: MCPSystemClock(),
            clientAddress: .loopback,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    static func toolCallParams(name: String, arguments: JsonValue) -> JsonValue {
        .object(["name": .string(name), "arguments": arguments])
    }

    static func snapshot(
        policy: AIConnectionPolicy = .alwaysAllow,
        externalAccess: ExternalAccessLevel = .readWrite,
        name: String = "Primary",
        databaseType: String = "PostgreSQL"
    ) -> MCPConnectionAuthSnapshot {
        MCPConnectionAuthSnapshot(
            policy: policy,
            externalAccess: externalAccess,
            name: name,
            databaseType: databaseType
        )
    }

    static func authPolicy(connections: [UUID: MCPConnectionAuthSnapshot] = [:]) -> MCPAuthPolicy {
        MCPAuthPolicy(
            connectionResolver: { id in connections[id] },
            connectionIdsProvider: { Set(connections.keys) }
        )
    }

    static func services(
        authPolicy: MCPAuthPolicy? = nil,
        settings: MCPSettings = MCPSettings(),
        history: QueryHistoryReading = ToolTestQueryHistoryStore()
    ) -> MCPToolServices {
        MCPToolServices(
            connectionBridge: MCPConnectionBridge(),
            authPolicy: authPolicy ?? self.authPolicy(),
            settingsProvider: { settings },
            queryHistoryManager: history
        )
    }

    static func metadata(
        connectionId: UUID = UUID(),
        databaseType: DatabaseType = .postgresql,
        safeModeLevel: SafeModeLevel = .silent,
        externalAccess: ExternalAccessLevel = .readWrite,
        databaseName: String = "shop",
        connectionName: String = "Primary",
        redactionSecrets: [String] = []
    ) -> ToolConnectionMetadata {
        ToolConnectionMetadata(
            connectionId: connectionId,
            databaseType: databaseType,
            safeModeLevel: safeModeLevel,
            externalAccess: externalAccess,
            databaseName: databaseName,
            connectionName: connectionName,
            redactionSecrets: redactionSecrets
        )
    }

    static func structuredPayload(_ result: MCPToolCallResult) -> JsonValue? {
        result.structuredContent
    }

    static func errorText(_ result: MCPToolCallResult) -> String? {
        for item in result.content {
            if case .text(let value) = item {
                return value
            }
        }
        return nil
    }
}
