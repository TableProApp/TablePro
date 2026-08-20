import Foundation
import TableProPluginKit
@testable import TablePro

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

actor ReleaseGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if released {
                continuation.resume()
                return
            }
            waiters.append(continuation)
        }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
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

actor MCPProtocolStubClock: MCPClock {
    private struct PendingSleep {
        let dueAt: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private var currentDate: Date
    private var pending: [UUID: PendingSleep] = [:]
    private var cancelledBeforeRegistration: Set<UUID> = []
    private(set) var completedSleeps: Int = 0

    init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        currentDate = start
    }

    func now() -> Date {
        currentDate
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        let dueAt = currentDate.addingTimeInterval(Self.seconds(of: duration))
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancelledBeforeRegistration.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = PendingSleep(dueAt: dueAt, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelSleep(id) }
        }
    }

    func advance(by duration: Duration) async {
        currentDate = currentDate.addingTimeInterval(Self.seconds(of: duration))
        resumeDueSleeps()
        await Task.yield()
    }

    func setNow(_ date: Date) async {
        currentDate = date
        resumeDueSleeps()
        await Task.yield()
    }

    func pendingSleepCount() -> Int {
        pending.count
    }

    private func cancelSleep(_ id: UUID) {
        guard let sleeper = pending.removeValue(forKey: id) else {
            cancelledBeforeRegistration.insert(id)
            return
        }
        sleeper.continuation.resume(throwing: CancellationError())
    }

    private func resumeDueSleeps() {
        let due = pending.filter { $0.value.dueAt <= currentDate }
        for (id, sleeper) in due {
            pending.removeValue(forKey: id)
            completedSleeps += 1
            sleeper.continuation.resume()
        }
    }

    private static func seconds(of duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1.0e18
    }
}

struct StubDriverError: LocalizedError, Sendable {
    let detail: String

    var errorDescription: String? {
        detail
    }
}

enum StubHandlerBehavior: Sendable {
    case returning(MCPResult)
    case failProtocol(MCPProtocolError)
    case failDriver(StubDriverError)
    case waitForCancellation
    case blockUntilReleased(ReleaseGate)
    case emitProgressThenComplete(Double)
}

protocol StubHandlerIdentity: Sendable {
    static var method: String { get }
    static var requiredScopes: Set<MCPScope> { get }
    static var isAvailableToLegacyClients: Bool { get }
}

extension StubHandlerIdentity {
    static var requiredScopes: Set<MCPScope> { [] }
    static var isAvailableToLegacyClients: Bool { true }
}

enum StubTestIdentity: StubHandlerIdentity {
    static let method = "test/stub"
}

enum StubModernOnlyIdentity: StubHandlerIdentity {
    static let method = "modern/only"
    static let isAvailableToLegacyClients = false
}

enum StubScopedIdentity: StubHandlerIdentity {
    static let method = "scoped/method"
    static let requiredScopes: Set<MCPScope> = [.admin, .toolsWrite]
}

enum StubToolsListIdentity: StubHandlerIdentity {
    static let method = "tools/list"
}

enum StubToolsCallIdentity: StubHandlerIdentity {
    static let method = "tools/call"
}

enum StubResourcesReadIdentity: StubHandlerIdentity {
    static let method = "resources/read"
}

struct StubHandler<Identity: StubHandlerIdentity>: MCPMethodHandler {
    static var method: String { Identity.method }
    static var requiredScopes: Set<MCPScope> { Identity.requiredScopes }
    static var isAvailableToLegacyClients: Bool { Identity.isAvailableToLegacyClients }

    let behavior: StubHandlerBehavior
    let started: ObservedFlag
    let observedCancellation: ObservedFlag

    init(behavior: StubHandlerBehavior = .returning(.complete(["ok": .bool(true)]))) {
        self.behavior = behavior
        started = ObservedFlag()
        observedCancellation = ObservedFlag()
    }

    func handle(params: JsonValue?, context: MCPRequestContext) async throws -> MCPResult {
        await started.set()
        switch behavior {
        case .returning(let result):
            return result
        case .failProtocol(let error):
            throw error
        case .failDriver(let error):
            throw error
        case .waitForCancellation:
            while true {
                if await context.cancellation.isCancelled {
                    await observedCancellation.set()
                    throw CancellationError()
                }
                try await Task.sleep(for: .milliseconds(5))
            }
        case .blockUntilReleased(let gate):
            await gate.wait()
            return .complete(["ok": .bool(true)])
        case .emitProgressThenComplete(let progress):
            await context.progress.emit(progress: progress)
            return .complete(["ok": .bool(true)])
        }
    }
}

typealias StubTestHandler = StubHandler<StubTestIdentity>
typealias StubModernOnlyHandler = StubHandler<StubModernOnlyIdentity>
typealias StubScopedHandler = StubHandler<StubScopedIdentity>
typealias StubToolsListHandler = StubHandler<StubToolsListIdentity>
typealias StubToolsCallHandler = StubHandler<StubToolsCallIdentity>
typealias StubResourcesReadHandler = StubHandler<StubResourcesReadIdentity>

enum MCPProtocolTestSupport {
    static let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    static func makePrincipal(
        fingerprint: String = "test-fp",
        tokenId: UUID? = UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
        scopes: Set<MCPScope> = [.toolsRead, .toolsWrite],
        connectionAccess: ConnectionAccess = .all,
        label: String = "test"
    ) -> MCPPrincipal {
        MCPPrincipal(
            tokenFingerprint: fingerprint,
            tokenId: tokenId,
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

    static func makeDispatcher(
        handlers: [any MCPMethodHandler],
        legacyAdapter: MCPLegacyEraAdapter = MCPLegacyEraAdapter(),
        clock: any MCPClock = MCPSystemClock(),
        handlerTimeout: Duration = .seconds(330),
        disconnectPollInterval: Duration = .seconds(60)
    ) -> MCPProtocolDispatcher {
        MCPProtocolDispatcher(
            handlers: handlers,
            legacyAdapter: legacyAdapter,
            activityLedger: MCPClientActivityLedger(),
            serverInfo: MCPImplementation(name: "tablepro", title: "TablePro", version: "1.2.3"),
            clock: clock,
            handlerTimeout: handlerTimeout,
            disconnectPollInterval: disconnectPollInterval
        )
    }

    static func jsonValue(fromJson text: String) throws -> JsonValue {
        try JSONDecoder().decode(JsonValue.self, from: Data(text.utf8))
    }
}
