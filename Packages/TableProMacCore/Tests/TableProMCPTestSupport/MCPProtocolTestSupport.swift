import Foundation
import TableProMCP

public actor RecordingResponderSink: MCPResponderSink {
    public struct WriteJsonRecord: Sendable {
        public let data: Data
        public let status: HttpStatus
        public let extraHeaders: [(String, String)]
    }

    public private(set) var jsonWrites: [WriteJsonRecord] = []
    public private(set) var acceptedCount: Int = 0
    public private(set) var sseHeadCount: Int = 0
    public private(set) var sseFrames: [SseFrame] = []
    public private(set) var closed: Bool = false

    private var clientGone: Bool = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var completed: Bool = false

    public init() {}

    public func writeJson(_ data: Data, status: HttpStatus, extraHeaders: [(String, String)]) async {
        jsonWrites.append(WriteJsonRecord(data: data, status: status, extraHeaders: extraHeaders))
    }

    public func writeAccepted() async {
        acceptedCount += 1
    }

    public func beginSseStream() async {
        sseHeadCount += 1
    }

    public func writeSseFrame(_ frame: SseFrame) async {
        sseFrames.append(frame)
    }

    public func closeConnection() async {
        closed = true
        finish()
    }

    public func isClosed() async -> Bool {
        clientGone
    }

    public func disconnectClient() {
        clientGone = true
    }

    public func waitForCompletion() async {
        if completed { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if completed {
                cont.resume()
                return
            }
            continuation = cont
        }
    }

    public func firstJsonMessage() throws -> JsonRpcMessage? {
        guard let record = jsonWrites.first else { return nil }
        return try JsonRpcCodec.decode(record.data)
    }

    public func firstJsonStatus() -> HttpStatus? {
        jsonWrites.first?.status
    }

    public func firstJsonBodyText() -> String {
        guard let record = jsonWrites.first else { return "" }
        return String(data: record.data, encoding: .utf8) ?? ""
    }

    public func firstHeaderValue(named name: String) -> String? {
        jsonWrites.first?.extraHeaders.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    public func successResult() throws -> JsonValue? {
        guard case .successResponse(let response)? = try firstJsonMessage() else { return nil }
        return response.result
    }

    public func errorEnvelope() throws -> JsonRpcError? {
        guard case .errorResponse(let response)? = try firstJsonMessage() else { return nil }
        return response.error
    }

    public func sseMessages() throws -> [JsonRpcMessage] {
        try sseFrames.map { try JsonRpcCodec.decode(Data($0.data.utf8)) }
    }

    private func finish() {
        guard !completed else { return }
        completed = true
        continuation?.resume()
        continuation = nil
    }
}

public actor ObservedFlag {
    private var triggered: Bool = false
    private var count: Int = 0

    public init() {}

    public func set() {
        triggered = true
        count += 1
    }

    public func value() -> Bool {
        triggered
    }

    public func times() -> Int {
        count
    }

    public func waitUntilSet(timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = Date().addingTimeInterval(Self.seconds(of: timeout))
        while Date() < deadline {
            if triggered { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return triggered
    }

    private static func seconds(of duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1.0e18
    }
}

public actor ObservedValue<Value: Sendable> {
    private var stored: Value?

    public init() {}

    public func set(_ value: Value) {
        stored = value
    }

    public func value() -> Value? {
        stored
    }
}

public enum MCPProtocolTestSupport {
    public static let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
    public static let defaultTokenId = UUID(uuid: (0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11))

    public static func makePrincipal(
        fingerprint: String = "test-fp",
        tokenId: UUID? = nil,
        scopes: Set<MCPScope> = [.toolsRead, .toolsWrite],
        connectionAccess: ConnectionAccess = .all,
        label: String = "test"
    ) -> MCPPrincipal {
        MCPPrincipal(
            tokenFingerprint: fingerprint,
            tokenId: tokenId ?? defaultTokenId,
            scopes: scopes,
            connectionAccess: connectionAccess,
            metadata: MCPPrincipalMetadata(label: label, issuedAt: referenceDate, expiresAt: nil)
        )
    }

    public static func metaFields(
        protocolVersion: MCPProtocolVersion = .latest,
        clientName: String? = "TestClient",
        clientVersion: String = "1.0.0",
        clientCapabilities: JsonValue = .object([:]),
        progressToken: JsonValue? = nil,
        traceContext: [String: String] = [:]
    ) -> [String: JsonValue] {
        var fields: [String: JsonValue] = [
            MCPMetaKeys.protocolVersion: .string(protocolVersion.rawValue),
            MCPMetaKeys.clientCapabilities: clientCapabilities
        ]
        if let clientName {
            fields[MCPMetaKeys.clientInfo] = .object([
                "name": .string(clientName),
                "version": .string(clientVersion)
            ])
        }
        if let progressToken {
            fields[MCPMetaKeys.progressToken] = progressToken
        }
        for (key, value) in traceContext {
            fields[key] = .string(value)
        }
        return fields
    }

    public static func modernParams(
        _ payload: [String: JsonValue] = [:],
        protocolVersion: MCPProtocolVersion = .latest,
        clientCapabilities: JsonValue = .object([:]),
        progressToken: JsonValue? = nil
    ) -> JsonValue {
        var fields = payload
        fields["_meta"] = .object(metaFields(
            protocolVersion: protocolVersion,
            clientCapabilities: clientCapabilities,
            progressToken: progressToken
        ))
        return .object(fields)
    }

    public static func makeMeta(
        protocolVersion: MCPProtocolVersion = .latest,
        clientName: String? = "TestClient",
        clientCapabilities: MCPClientCapabilities = .none,
        progressToken: MCPProgressToken? = nil,
        traceContext: [String: String] = [:]
    ) -> MCPRequestMeta {
        MCPRequestMeta(
            protocolVersion: protocolVersion,
            clientInfo: clientName.map { MCPImplementation(name: $0, version: "1.0.0") },
            clientCapabilities: clientCapabilities,
            progressToken: progressToken,
            traceContext: traceContext
        )
    }

    public static func makeRequest(
        id: JsonRpcId = .number(1),
        method: String,
        params: JsonValue? = nil
    ) -> JsonRpcMessage {
        .request(JsonRpcRequest(id: id, method: method, params: params))
    }

    public static func makeModernRequest(
        id: JsonRpcId = .number(1),
        method: String,
        payload: [String: JsonValue] = [:],
        protocolVersion: MCPProtocolVersion = .latest,
        clientCapabilities: JsonValue = .object([:]),
        progressToken: JsonValue? = nil
    ) -> JsonRpcMessage {
        .request(JsonRpcRequest(
            id: id,
            method: method,
            params: modernParams(
                payload,
                protocolVersion: protocolVersion,
                clientCapabilities: clientCapabilities,
                progressToken: progressToken
            )
        ))
    }

    public static func makeNotification(method: String, params: JsonValue? = nil) -> JsonRpcMessage {
        .notification(JsonRpcNotification(method: method, params: params))
    }

    public static func makeExchange(
        message: JsonRpcMessage,
        principal: MCPPrincipal? = makePrincipal(),
        clientAddress: MCPClientAddress = .loopback,
        receivedAt: Date = referenceDate,
        transportProtocolVersion: String? = nil,
        legacySessionId: MCPLegacySessionId? = nil
    ) -> (MCPInboundExchange, RecordingResponderSink) {
        let sink = RecordingResponderSink()
        let requestId: JsonRpcId?
        if case .request(let request) = message {
            requestId = request.id
        } else {
            requestId = nil
        }
        let responder = MCPResponder(sink: sink, requestId: requestId)
        let context = MCPInboundContext(
            principal: principal,
            clientAddress: clientAddress,
            receivedAt: receivedAt,
            transportProtocolVersion: transportProtocolVersion,
            legacySessionId: legacySessionId
        )
        return (MCPInboundExchange(message: message, context: context, responder: responder), sink)
    }

    public static func jsonValue(fromJson text: String) throws -> JsonValue {
        try JSONDecoder().decode(JsonValue.self, from: Data(text.utf8))
    }
}
