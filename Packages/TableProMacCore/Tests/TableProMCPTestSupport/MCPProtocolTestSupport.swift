import Foundation
import TableProMCP

actor RecordingResponderSink: MCPResponderSink {
    struct WriteJsonRecord {
        let data: Data
        let status: HttpStatus
        let extraHeaders: [(String, String)]
    }

    private(set) var jsonWrites: [WriteJsonRecord] = []
    private(set) var acceptedCount: Int = 0
    private(set) var sseHeadCount: Int = 0
    private(set) var sseFrames: [SseFrame] = []
    private(set) var closed: Bool = false

    private var clientGone: Bool = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var completed: Bool = false

    func writeJson(_ data: Data, status: HttpStatus, extraHeaders: [(String, String)]) async {
        jsonWrites.append(WriteJsonRecord(data: data, status: status, extraHeaders: extraHeaders))
    }

    func writeAccepted() async {
        acceptedCount += 1
    }

    func beginSseStream() async {
        sseHeadCount += 1
    }

    func writeSseFrame(_ frame: SseFrame) async {
        sseFrames.append(frame)
    }

    func closeConnection() async {
        closed = true
        finish()
    }

    func isClosed() async -> Bool {
        clientGone
    }

    func disconnectClient() {
        clientGone = true
    }

    func waitForCompletion() async {
        if completed { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if completed {
                cont.resume()
                return
            }
            continuation = cont
        }
    }

    func firstJsonMessage() throws -> JsonRpcMessage? {
        guard let record = jsonWrites.first else { return nil }
        return try JsonRpcCodec.decode(record.data)
    }

    func firstJsonStatus() -> HttpStatus? {
        jsonWrites.first?.status
    }

    func firstJsonBodyText() -> String {
        guard let record = jsonWrites.first else { return "" }
        return String(data: record.data, encoding: .utf8) ?? ""
    }

    func firstHeaderValue(named name: String) -> String? {
        jsonWrites.first?.extraHeaders.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    func successResult() throws -> JsonValue? {
        guard case .successResponse(let response)? = try firstJsonMessage() else { return nil }
        return response.result
    }

    func errorEnvelope() throws -> JsonRpcError? {
        guard case .errorResponse(let response)? = try firstJsonMessage() else { return nil }
        return response.error
    }

    func sseMessages() throws -> [JsonRpcMessage] {
        try sseFrames.map { try JsonRpcCodec.decode(Data($0.data.utf8)) }
    }

    private func finish() {
        guard !completed else { return }
        completed = true
        continuation?.resume()
        continuation = nil
    }
}

actor ObservedFlag {
    private var triggered: Bool = false
    private var count: Int = 0

    func set() {
        triggered = true
        count += 1
    }

    func value() -> Bool {
        triggered
    }

    func times() -> Int {
        count
    }

    func waitUntilSet(timeout: Duration = .seconds(2)) async -> Bool {
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

actor ObservedValue<Value: Sendable> {
    private var stored: Value?

    func set(_ value: Value) {
        stored = value
    }

    func value() -> Value? {
        stored
    }
}

enum MCPProtocolTestSupport {
    static let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
    static let defaultTokenId = UUID(uuid: (0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11))

    static func makePrincipal(
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

    static func metaFields(
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

    static func modernParams(
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

    static func makeMeta(
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

    static func makeRequest(
        id: JsonRpcId = .number(1),
        method: String,
        params: JsonValue? = nil
    ) -> JsonRpcMessage {
        .request(JsonRpcRequest(id: id, method: method, params: params))
    }

    static func makeModernRequest(
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

    static func makeNotification(method: String, params: JsonValue? = nil) -> JsonRpcMessage {
        .notification(JsonRpcNotification(method: method, params: params))
    }

    static func makeExchange(
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

    static func jsonValue(fromJson text: String) throws -> JsonValue {
        try JSONDecoder().decode(JsonValue.self, from: Data(text.utf8))
    }
}
