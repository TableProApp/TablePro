//
//  MCPClientSession.swift
//  TablePro
//

import Foundation
import os

internal struct MCPRemoteTool: Equatable, Sendable {
    internal let name: String
    internal let description: String
    internal let inputSchema: JsonValue
}

internal enum MCPClientError: Error, Equatable, Sendable {
    case notConfigured
    case timedOut
    case transport(String)
    case server(code: Int, message: String)
    case malformedResponse
    /// The server forgot the session it issued. Recoverable by initializing again, which is what
    /// separates it from `transport`: the call is retried once rather than reported.
    case sessionExpired

    internal var localizedMessage: String {
        switch self {
        case .notConfigured:
            return String(localized: "This server has no credential. Add its token in Settings > Integrations.")
        case .timedOut:
            return String(localized: "The server did not answer in time.")
        case .transport(let detail):
            return detail
        case .server(_, let message):
            return message
        case .malformedResponse:
            return String(localized: "The server's answer could not be read.")
        case .sessionExpired:
            return String(localized: "The server ended the session.")
        }
    }
}

/// One conversation with an outside MCP server: initialize, list its tools, call one.
///
/// The transport underneath answers each request on its own response, so there is no id correlation
/// here and no reader task to own. What is left is the protocol's own lifecycle, which has three
/// parts a client does not get to skip: `initialize`, the `notifications/initialized` that follows
/// it, and the session id the server may issue on the way through.
internal actor MCPClientSession {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "MCPClientSession")

    /// Short on purpose. This sits inside a chat turn, and a reader watching a reply stop is a worse
    /// outcome than a tool call that reports a timeout the model can work around.
    internal static let defaultTimeout: Duration = .seconds(30)

    private let configuration: MCPServerConfiguration
    private let transport: MCPRemoteServerTransport

    private var nextRequestId = 1
    private var handshake: Task<Void, Error>?
    private var isClosed = false

    internal init(
        configuration: MCPServerConfiguration,
        transport: MCPRemoteServerTransport
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    /// Builds a session against a stored server, or nil when it has no credential. A server with no
    /// token is not called with none: an unauthenticated request to a URL the user configured for an
    /// authenticated one is a request they did not ask for.
    @MainActor
    internal static func make(
        configuration: MCPServerConfiguration,
        store: MCPServerStore = .shared,
        timeout: Duration = MCPClientSession.defaultTimeout
    ) -> MCPClientSession? {
        guard let token = store.token(for: configuration.id) else { return nil }
        return MCPClientSession(
            configuration: configuration,
            transport: MCPRemoteServerTransport(
                endpoint: configuration.endpoint,
                bearerToken: token,
                timeout: timeout
            )
        )
    }

    /// Every page of the server's tools.
    ///
    /// `tools/list` is paginated: a server with more tools than it wants to send at once answers
    /// with a `nextCursor`, and a client that ignores it registers the first page and silently
    /// offers the model a subset of what the server has. Pages are followed until the cursor stops
    /// coming, bounded so a server that returns a cursor forever cannot loop here.
    internal func listTools() async throws -> [MCPRemoteTool] {
        var tools: [MCPRemoteTool] = []
        var cursor: String?
        for _ in 0..<Self.maximumToolPages {
            let params: JsonValue? = cursor.map { .object(["cursor": .string($0)]) }
            let result = try await call(method: "tools/list", params: params)
            guard case .object(let fields) = result, case .array(let rawTools)? = fields["tools"] else {
                throw MCPClientError.malformedResponse
            }
            tools.append(contentsOf: rawTools.compactMap(Self.decodeTool))
            guard case .string(let next)? = fields["nextCursor"], !next.isEmpty else { return tools }
            cursor = next
        }
        Self.logger.warning(
            "MCP server \(self.configuration.id, privacy: .public) kept paginating its tools; stopping"
        )
        return tools
    }

    /// Enough for any real server and a backstop against one that always returns a cursor.
    private static let maximumToolPages = 20

    /// Calls one tool and returns its content as text.
    ///
    /// The result is text, never parsed for anything the app then acts on. A remote server's answer
    /// is data: a result that reads like an instruction is shown to the reader and ignored by
    /// everything else.
    internal func callTool(name: String, arguments: JsonValue) async throws -> String {
        let result = try await call(
            method: "tools/call",
            params: .object(["name": .string(name), "arguments": arguments])
        )
        return Self.flattenContent(result)
    }

    internal func close() async {
        guard !isClosed else { return }
        isClosed = true
        handshake?.cancel()
        handshake = nil
        await transport.close()
    }

    // MARK: - Protocol

    /// Runs the handshake if it has not run, then the call, retrying once when the server reports
    /// that it has forgotten the session. A session id can expire between two turns of a
    /// conversation, and re-initializing is the specification's own answer to that.
    private func call(method: String, params: JsonValue?) async throws -> JsonValue {
        guard !isClosed else { throw MCPClientError.transport(Self.closedMessage) }
        try await initializeIfNeeded()
        do {
            return try await send(method: method, params: params)
        } catch MCPClientError.sessionExpired {
            Self.logger.info(
                "MCP server \(self.configuration.id, privacy: .public) ended its session; initializing again"
            )
            handshake = nil
            try await initializeIfNeeded()
            return try await send(method: method, params: params)
        }
    }

    /// The handshake is held as a task rather than a `Bool`.
    ///
    /// A flag set before the round trip leaves a failed initialize looking finished, so every later
    /// call runs against a server that never handshook and gets refused for a reason nothing here
    /// reports. A flag set after it lets two concurrent calls each run one. The task does both: the
    /// second caller awaits the first one's, and a throw clears it so the next call tries again.
    private func initializeIfNeeded() async throws {
        if let handshake {
            try await handshake.value
            return
        }
        let task = Task { try await performHandshake() }
        handshake = task
        do {
            try await task.value
        } catch {
            handshake = nil
            throw error
        }
    }

    /// `initialize`, then `notifications/initialized`.
    ///
    /// The notification is not optional. The specification has the client send it once the
    /// initialize response is in, and a server that holds itself to the lifecycle refuses
    /// `tools/list` until it arrives, so a client that skips it lists no tools at all on exactly the
    /// servers that implement the protocol most carefully.
    private func performHandshake() async throws {
        let request = JsonRpcRequest(
            id: takeRequestId(),
            method: "initialize",
            params: .object([
                "protocolVersion": .string(MCPProtocolVersion.latest.rawValue),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("TablePro"),
                    "version": .string(Bundle.main.appVersion)
                ])
            ])
        )
        guard let body = try? JsonRpcCodec.encode(.request(request)) else {
            throw MCPClientError.malformedResponse
        }
        let result = try await transport.send(request: body, isInitialize: true)

        /// The version the server chose, not the one TablePro asked for. A server may answer an
        /// older one, and every request after this carries `MCP-Protocol-Version`, so continuing to
        /// send the newest is telling it something it just declined.
        if case .object(let fields) = result, case .string(let negotiated)? = fields["protocolVersion"] {
            await transport.adopt(protocolVersion: MCPProtocolVersion(negotiated))
        }

        let initialized = JsonRpcNotification(method: "notifications/initialized")
        guard let notificationBody = try? JsonRpcCodec.encode(.notification(initialized)) else {
            throw MCPClientError.malformedResponse
        }
        try await transport.send(notification: notificationBody)
    }

    private func send(method: String, params: JsonValue?) async throws -> JsonValue {
        let request = JsonRpcRequest(id: takeRequestId(), method: method, params: params)
        guard let body = try? JsonRpcCodec.encode(.request(request)) else {
            throw MCPClientError.malformedResponse
        }
        return try await transport.send(request: body)
    }

    private func takeRequestId() -> JsonRpcId {
        defer { nextRequestId += 1 }
        return .number(Int64(nextRequestId))
    }

    private static var closedMessage: String {
        String(localized: "The connection to the server was closed.")
    }

    // MARK: - Decoding

    private static func decodeTool(_ value: JsonValue) -> MCPRemoteTool? {
        guard case .object(let fields) = value,
              case .string(let name)? = fields["name"],
              !name.isEmpty
        else { return nil }
        let description: String
        if case .string(let text)? = fields["description"] {
            description = text
        } else {
            description = ""
        }
        return MCPRemoteTool(
            name: name,
            description: description,
            inputSchema: fields["inputSchema"] ?? .object([:])
        )
    }

    /// MCP returns content as an array of typed parts. Only text is taken: an image or an embedded
    /// resource from an outside server would be a second thing to trust, and the tool result the
    /// model reads is text either way.
    internal static func flattenContent(_ result: JsonValue) -> String {
        guard case .object(let fields) = result else { return "" }
        guard case .array(let parts)? = fields["content"] else {
            return fields["structuredContent"]?.jsonString(prettyPrinted: true) ?? ""
        }
        let texts: [String] = parts.compactMap { part in
            guard case .object(let partFields) = part,
                  case .string("text")? = partFields["type"],
                  case .string(let text)? = partFields["text"]
            else { return nil }
            return text
        }
        return texts.joined(separator: "\n")
    }
}
