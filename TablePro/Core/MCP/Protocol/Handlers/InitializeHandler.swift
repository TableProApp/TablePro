import Foundation
import os

public struct InitializeHandler: MCPMethodHandler {
    public static let method = "initialize"
    public static let requiredScopes: Set<MCPScope> = []
    public static let allowedSessionStates: Set<MCPSessionAllowedState> = [.uninitialized]

    public static let supportedProtocolVersion = "2025-11-25"
    public static let supportedProtocolVersions: Set<String> = [
        "2025-03-26",
        "2025-06-18",
        "2025-11-25"
    ]

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Handler.Initialize")

    public init() {}

    public func handle(params: JsonValue?, context: MCPRequestContext) async throws -> JsonRpcMessage {
        let sessionState = await context.session.state
        if case .ready = sessionState {
            throw MCPProtocolError.invalidRequest(detail: "Session already initialized")
        }
        if await context.session.clientInfo != nil {
            throw MCPProtocolError.invalidRequest(detail: "initialize already received for this session")
        }

        let requestedVersion = params?["protocolVersion"]?.stringValue
        let protocolVersion = Self.negotiate(requestedVersion: requestedVersion)

        let clientCapabilities = params?["capabilities"]
        let clientName = params?["clientInfo"]?["name"]?.stringValue ?? "unknown"
        let clientVersion = params?["clientInfo"]?["version"]?.stringValue

        let info = MCPClientInfo(name: clientName, version: clientVersion)
        await context.session.recordInitialize(
            clientInfo: info,
            protocolVersion: protocolVersion,
            capabilities: clientCapabilities
        )

        let result: JsonValue = .object([
            "protocolVersion": .string(protocolVersion),
            "capabilities": .object([
                "tools": .object(["listChanged": .bool(false)]),
                "resources": .object([
                    "listChanged": .bool(false),
                    "subscribe": .bool(false)
                ]),
                "prompts": .object(["listChanged": .bool(false)]),
                "logging": .object([:]),
                "completions": .object([:])
            ]),
            "serverInfo": .object([
                "name": .string("tablepro"),
                "title": .string("TablePro"),
                "version": .string(Self.serverVersion)
            ])
        ])

        Self.logger.info(
            "Initialize: client=\(clientName, privacy: .public) version=\(clientVersion ?? "-", privacy: .public) protocol=\(protocolVersion, privacy: .public) requested=\(requestedVersion ?? "-", privacy: .public)"
        )
        return MCPMethodHandlerHelpers.successResponse(id: context.requestId, result: result)
    }

    public static func negotiate(requestedVersion: String?) -> String {
        guard let requestedVersion, !requestedVersion.isEmpty else {
            return supportedProtocolVersion
        }
        if supportedProtocolVersions.contains(requestedVersion) {
            return requestedVersion
        }
        return supportedProtocolVersion
    }

    private static let serverVersion: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }()
}
