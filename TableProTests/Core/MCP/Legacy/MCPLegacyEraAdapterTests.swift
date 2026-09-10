import Foundation
@testable import TablePro
import Testing

@Suite("MCP legacy era adapter")
struct MCPLegacyEraAdapterTests {
    @Test("A request whose _meta declares a protocol version is served by the modern era")
    func modernMetaSelectsTheModernEra() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()

        let resolution = try await adapter.resolve(
            message: MCPLegacyTestSupport.request(method: "tools/list", params: MCPLegacyTestSupport.modernParams()),
            inbound: MCPLegacyTestSupport.inbound()
        )

        guard case .modern(let meta) = resolution else {
            Issue.record("Expected the modern era, got \(resolution)")
            return
        }
        #expect(meta.era == .modern)
        #expect(meta.protocolVersion == .v20260728)
        #expect(meta.clientInfo?.name == "modern-client")
        let sessions = await adapter.sessionCount()
        #expect(sessions == 0)
    }

    @Test("The modern era needs no session, so an Mcp-Session-Id on a modern request is never read")
    func modernRequestsIgnoreAnyPresentedSessionId() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()

        let resolution = try await adapter.resolve(
            message: MCPLegacyTestSupport.request(method: "tools/list", params: MCPLegacyTestSupport.modernParams()),
            inbound: MCPLegacyTestSupport.inbound(sessionId: MCPLegacySessionId.generate())
        )

        guard case .modern = resolution else {
            Issue.record("Expected the modern era, got \(resolution)")
            return
        }
        let sessions = await adapter.sessionCount()
        #expect(sessions == 0)
    }

    @Test("The method initialize selects the legacy initialize path")
    func initializeRequestSelectsTheLegacyInitializePath() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()

        let resolution = try await adapter.resolve(
            message: MCPLegacyTestSupport.request(
                method: "initialize",
                params: MCPLegacyTestSupport.initializeParams()
            ),
            inbound: MCPLegacyTestSupport.inbound()
        )

        guard case .legacyInitialize = resolution else {
            Issue.record("Expected the legacy initialize path, got \(resolution)")
            return
        }
    }

    @Test("Modern _meta on an initialize request wins over the legacy initialize path")
    func modernMetaOnInitializeStaysOnTheModernEra() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()

        let resolution = try await adapter.resolve(
            message: MCPLegacyTestSupport.request(method: "initialize", params: MCPLegacyTestSupport.modernParams()),
            inbound: MCPLegacyTestSupport.inbound()
        )

        guard case .modern = resolution else {
            Issue.record("Expected the modern era, got \(resolution)")
            return
        }
    }

    @Test("An Mcp-Session-Id naming a live session selects the legacy era")
    func liveSessionIdSelectsTheLegacyEra() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()
        let principal = MCPLegacyTestSupport.principal(fingerprint: "alice")
        let (_, sessionId) = try await adapter.handleInitialize(
            params: MCPLegacyTestSupport.initializeParams(),
            principal: principal
        )

        let resolution = try await adapter.resolve(
            message: MCPLegacyTestSupport.request(method: "tools/list"),
            inbound: MCPLegacyTestSupport.inbound(principal: principal, sessionId: sessionId)
        )

        guard case .legacy(let meta, let resolvedId) = resolution else {
            Issue.record("Expected the legacy era, got \(resolution)")
            return
        }
        #expect(resolvedId == sessionId)
        #expect(meta.era == .legacy)
    }

    @Test("The synthesised legacy meta carries the handshake recorded at initialize time")
    func synthesizedLegacyMetaCarriesTheRecordedHandshake() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()
        let principal = MCPLegacyTestSupport.principal(fingerprint: "alice")
        let (_, sessionId) = try await adapter.handleInitialize(
            params: MCPLegacyTestSupport.initializeParams(
                version: MCPProtocolVersion.v20250618.rawValue,
                clientName: "acme-cli",
                clientVersion: "9.9.9",
                capabilities: .object(["elicitation": .object([:]), "sampling": .object([:])])
            ),
            principal: principal
        )

        let resolution = try await adapter.resolve(
            message: MCPLegacyTestSupport.request(method: "tools/call"),
            inbound: MCPLegacyTestSupport.inbound(principal: principal, sessionId: sessionId)
        )

        guard case .legacy(let meta, _) = resolution else {
            Issue.record("Expected the legacy era, got \(resolution)")
            return
        }
        #expect(meta.protocolVersion == .v20250618)
        #expect(meta.clientInfo?.name == "acme-cli")
        #expect(meta.clientInfo?.version == "9.9.9")
        #expect(meta.clientCapabilities.supportsElicitation)
        #expect(meta.clientCapabilities.supportsSampling)
        #expect(!meta.clientCapabilities.supportsRoots)
    }

    @Test("A legacy request still contributes its own progress token and trace context")
    func synthesizedLegacyMetaKeepsPerRequestMetaFields() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()
        let principal = MCPLegacyTestSupport.principal(fingerprint: "alice")
        let (_, sessionId) = try await adapter.handleInitialize(
            params: MCPLegacyTestSupport.initializeParams(),
            principal: principal
        )
        let params = JsonValue.object([
            "_meta": .object([
                MCPMetaKeys.progressToken: .string("p-1"),
                MCPMetaKeys.traceParent: .string("00-trace-span-01")
            ])
        ])

        let resolution = try await adapter.resolve(
            message: MCPLegacyTestSupport.request(method: "tools/call", params: params),
            inbound: MCPLegacyTestSupport.inbound(principal: principal, sessionId: sessionId)
        )

        guard case .legacy(let meta, _) = resolution else {
            Issue.record("Expected the legacy era, got \(resolution)")
            return
        }
        #expect(meta.progressToken == .string("p-1"))
        #expect(meta.traceContext[MCPMetaKeys.traceParent] == "00-trace-span-01")
    }

    @Test("An Mcp-Session-Id naming no session is refused")
    func unknownSessionIdIsRefused() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()

        let error = await #expect(throws: MCPProtocolError.self) {
            _ = try await adapter.resolve(
                message: MCPLegacyTestSupport.request(method: "tools/list"),
                inbound: MCPLegacyTestSupport.inbound(sessionId: MCPLegacySessionId.generate())
            )
        }

        #expect(error?.code == JsonRpcErrorCode.sessionNotFound)
        #expect(error?.httpStatus == .notFound)
    }

    @Test("Neither modern _meta nor a session id is invalid params")
    func requestWithNoEraEvidenceIsInvalidParams() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()

        let error = await #expect(throws: MCPProtocolError.self) {
            _ = try await adapter.resolve(
                message: MCPLegacyTestSupport.request(method: "tools/list"),
                inbound: MCPLegacyTestSupport.inbound()
            )
        }

        #expect(error?.code == JsonRpcErrorCode.invalidParams)
        #expect(error?.httpStatus == .badRequest)
    }

    @Test("A session presented without an authenticated principal is refused as unauthenticated")
    func sessionPresentedWithoutAPrincipalIsRefused() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()
        let (_, sessionId) = try await adapter.handleInitialize(
            params: MCPLegacyTestSupport.initializeParams(),
            principal: MCPLegacyTestSupport.principal(fingerprint: "alice")
        )

        let error = await #expect(throws: MCPProtocolError.self) {
            _ = try await adapter.resolve(
                message: MCPLegacyTestSupport.request(method: "tools/list"),
                inbound: MCPLegacyTestSupport.inbound(principal: nil, sessionId: sessionId)
            )
        }

        #expect(error?.code == JsonRpcErrorCode.unauthenticated)
        #expect(error?.httpStatus == .unauthorized)
    }

    @Test("A session is bound to the token that created it, so another principal cannot present it")
    func differentPrincipalCannotPresentSomeoneElsesSession() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()
        let alice = MCPLegacyTestSupport.principal(fingerprint: "alice", tokenId: UUID())
        let mallory = MCPLegacyTestSupport.principal(fingerprint: "mallory", tokenId: UUID())
        let (_, sessionId) = try await adapter.handleInitialize(
            params: MCPLegacyTestSupport.initializeParams(),
            principal: alice
        )

        let error = await #expect(throws: MCPProtocolError.self) {
            _ = try await adapter.resolve(
                message: MCPLegacyTestSupport.request(method: "tools/list"),
                inbound: MCPLegacyTestSupport.inbound(principal: mallory, sessionId: sessionId)
            )
        }

        #expect(error?.code == JsonRpcErrorCode.sessionNotFound)
        #expect(error?.httpStatus == .notFound)
    }

    @Test("A refused hijack leaves the owner's session usable")
    func refusedHijackDoesNotDisturbTheOwner() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()
        let alice = MCPLegacyTestSupport.principal(fingerprint: "alice", tokenId: UUID())
        let mallory = MCPLegacyTestSupport.principal(fingerprint: "mallory", tokenId: UUID())
        let (_, sessionId) = try await adapter.handleInitialize(
            params: MCPLegacyTestSupport.initializeParams(),
            principal: alice
        )
        _ = try? await adapter.resolve(
            message: MCPLegacyTestSupport.request(method: "tools/list"),
            inbound: MCPLegacyTestSupport.inbound(principal: mallory, sessionId: sessionId)
        )

        let resolution = try await adapter.resolve(
            message: MCPLegacyTestSupport.request(method: "tools/list"),
            inbound: MCPLegacyTestSupport.inbound(principal: alice, sessionId: sessionId)
        )

        guard case .legacy(_, let resolvedId) = resolution else {
            Issue.record("Expected the owner's session to survive, got \(resolution)")
            return
        }
        #expect(resolvedId == sessionId)
        let sessions = await adapter.sessionCount()
        #expect(sessions == 1)
    }

    @Test("A token fingerprint alone does not unlock a session minted for another token id")
    func reusedFingerprintUnderAnotherTokenIdIsRefused() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()
        let owner = MCPLegacyTestSupport.principal(fingerprint: "shared-fp", tokenId: UUID())
        let impostor = MCPLegacyTestSupport.principal(fingerprint: "shared-fp", tokenId: UUID())
        let (_, sessionId) = try await adapter.handleInitialize(
            params: MCPLegacyTestSupport.initializeParams(),
            principal: owner
        )

        let error = await #expect(throws: MCPProtocolError.self) {
            _ = try await adapter.resolve(
                message: MCPLegacyTestSupport.request(method: "tools/list"),
                inbound: MCPLegacyTestSupport.inbound(principal: impostor, sessionId: sessionId)
            )
        }

        #expect(error?.code == JsonRpcErrorCode.sessionNotFound)
    }

    @Test("An MCP-Protocol-Version header that contradicts the session is a header mismatch")
    func contradictoryTransportVersionIsAHeaderMismatch() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()
        let principal = MCPLegacyTestSupport.principal(fingerprint: "alice")
        let (_, sessionId) = try await adapter.handleInitialize(
            params: MCPLegacyTestSupport.initializeParams(version: MCPProtocolVersion.v20251125.rawValue),
            principal: principal
        )

        let error = await #expect(throws: MCPProtocolError.self) {
            _ = try await adapter.resolve(
                message: MCPLegacyTestSupport.request(method: "tools/list"),
                inbound: MCPLegacyTestSupport.inbound(
                    principal: principal,
                    sessionId: sessionId,
                    transportProtocolVersion: MCPProtocolVersion.v20250618.rawValue
                )
            )
        }

        #expect(error?.code == JsonRpcErrorCode.headerMismatch)
        #expect(error?.httpStatus == .badRequest)
    }

    @Test("An MCP-Protocol-Version header matching the session is accepted")
    func matchingTransportVersionIsAccepted() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()
        let principal = MCPLegacyTestSupport.principal(fingerprint: "alice")
        let (_, sessionId) = try await adapter.handleInitialize(
            params: MCPLegacyTestSupport.initializeParams(version: MCPProtocolVersion.v20251125.rawValue),
            principal: principal
        )

        let resolution = try await adapter.resolve(
            message: MCPLegacyTestSupport.request(method: "tools/list"),
            inbound: MCPLegacyTestSupport.inbound(
                principal: principal,
                sessionId: sessionId,
                transportProtocolVersion: MCPProtocolVersion.v20251125.rawValue
            )
        )

        guard case .legacy = resolution else {
            Issue.record("Expected the legacy era, got \(resolution)")
            return
        }
    }

    @Test("Only a real initialize request mints a session")
    func onlyAnInitializeRequestMintsASession() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()

        let before = await adapter.sessionCount()
        _ = try await adapter.handleInitialize(
            params: MCPLegacyTestSupport.initializeParams(),
            principal: MCPLegacyTestSupport.principal(fingerprint: "alice")
        )
        let after = await adapter.sessionCount()

        #expect(before == 0)
        #expect(after == 1)
    }

    @Test("An initialize notification mints no session and is not the legacy initialize path")
    func initializeNotificationMintsNothing() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()

        let error = await #expect(throws: MCPProtocolError.self) {
            _ = try await adapter.resolve(
                message: .notification(JsonRpcNotification(
                    method: "initialize",
                    params: MCPLegacyTestSupport.initializeParams()
                )),
                inbound: MCPLegacyTestSupport.inbound()
            )
        }

        #expect(error?.code == JsonRpcErrorCode.invalidParams)
        let sessions = await adapter.sessionCount()
        #expect(sessions == 0)
    }

    @Test("Repeating the same handshake reuses the session instead of minting a second one")
    func repeatedInitializeReusesTheSameSession() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()
        let principal = MCPLegacyTestSupport.principal(fingerprint: "alice")

        let (_, first) = try await adapter.handleInitialize(
            params: MCPLegacyTestSupport.initializeParams(),
            principal: principal
        )
        let (_, second) = try await adapter.handleInitialize(
            params: MCPLegacyTestSupport.initializeParams(),
            principal: principal
        )

        #expect(first == second)
        let sessions = await adapter.sessionCount()
        #expect(sessions == 1)
    }

    @Test("Fifteen handshakes from one client never exhaust the session capacity")
    func repeatedHandshakesNeverExhaustCapacity() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()
        let principal = MCPLegacyTestSupport.principal(fingerprint: "alice")

        var ids: Set<MCPLegacySessionId> = []
        for _ in 0 ..< 15 {
            let (_, sessionId) = try await adapter.handleInitialize(
                params: MCPLegacyTestSupport.initializeParams(),
                principal: principal
            )
            ids.insert(sessionId)
        }

        #expect(ids.count == 1)
        let sessions = await adapter.sessionCount()
        #expect(sessions == 1)
    }

    @Test("Two different clients get two different sessions")
    func twoClientsGetTwoSessions() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()

        let (_, alice) = try await adapter.handleInitialize(
            params: MCPLegacyTestSupport.initializeParams(clientName: "alice-cli"),
            principal: MCPLegacyTestSupport.principal(fingerprint: "alice", tokenId: UUID())
        )
        let (_, bob) = try await adapter.handleInitialize(
            params: MCPLegacyTestSupport.initializeParams(clientName: "bob-cli"),
            principal: MCPLegacyTestSupport.principal(fingerprint: "bob", tokenId: UUID())
        )

        #expect(alice != bob)
        let sessions = await adapter.sessionCount()
        #expect(sessions == 2)
    }

    @Test("Initialize refuses an unsupported protocol version instead of downgrading")
    func initializeRejectsUnsupportedProtocolVersion() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()

        let error = await #expect(throws: MCPProtocolError.self) {
            _ = try await adapter.handleInitialize(
                params: MCPLegacyTestSupport.initializeParams(version: "1999-01-01"),
                principal: MCPLegacyTestSupport.principal(fingerprint: "vintage")
            )
        }

        #expect(error?.code == JsonRpcErrorCode.unsupportedProtocolVersion)
        #expect(error?.httpStatus == .badRequest)
        #expect(error?.data?["requested"]?.stringValue == "1999-01-01")
        let sessions = await adapter.sessionCount()
        #expect(sessions == 0)
    }

    @Test("Initialize refuses 2025-03-26")
    func initializeRejectsTheRetiredMarch2025Version() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()

        let error = await #expect(throws: MCPProtocolError.self) {
            _ = try await adapter.handleInitialize(
                params: MCPLegacyTestSupport.initializeParams(version: "2025-03-26"),
                principal: MCPLegacyTestSupport.principal(fingerprint: "vintage")
            )
        }

        #expect(error?.code == JsonRpcErrorCode.unsupportedProtocolVersion)
        let supported = error?.data?["supported"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(!supported.contains("2025-03-26"))
        #expect(supported == MCPProtocolVersion.supportedRawValues)
    }

    @Test("A modern _meta naming an unsupported version is refused with -32022, never downgraded")
    func modernMetaWithAnUnsupportedVersionIsRefused() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()

        let error = await #expect(throws: MCPProtocolError.self) {
            _ = try await adapter.resolve(
                message: MCPLegacyTestSupport.request(
                    method: "tools/list",
                    params: MCPLegacyTestSupport.modernParams(version: "2025-03-26")
                ),
                inbound: MCPLegacyTestSupport.inbound()
            )
        }

        #expect(error?.code == JsonRpcErrorCode.unsupportedProtocolVersion)
        #expect(error?.httpStatus == .badRequest)
    }

    @Test("A modern _meta without clientCapabilities is invalid params")
    func modernMetaWithoutClientCapabilitiesIsInvalidParams() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()
        let params = JsonValue.object([
            "_meta": .object([MCPMetaKeys.protocolVersion: .string(MCPProtocolVersion.latest.rawValue)])
        ])

        let error = await #expect(throws: MCPProtocolError.self) {
            _ = try await adapter.resolve(
                message: MCPLegacyTestSupport.request(method: "tools/list", params: params),
                inbound: MCPLegacyTestSupport.inbound()
            )
        }

        #expect(error?.code == JsonRpcErrorCode.invalidParams)
        #expect(error?.httpStatus == .badRequest)
    }

    @Test("Terminating a session cancels the work it still has in flight")
    func terminatingASessionCancelsItsInFlightWork() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()
        let principal = MCPLegacyTestSupport.principal(fingerprint: "alice")
        let (_, sessionId) = try await adapter.handleInitialize(
            params: MCPLegacyTestSupport.initializeParams(),
            principal: principal
        )
        let token = MCPCancellationToken()
        await adapter.trackInFlight(sessionId: sessionId, requestId: .number(7), cancellation: token)

        await adapter.terminate(sessionId: sessionId)

        let cancelled = await token.isCancelled
        let reason = await token.reason
        #expect(cancelled)
        #expect(reason == .clientRequested(nil))
        let sessions = await adapter.sessionCount()
        #expect(sessions == 0)
    }

    @Test("A terminated session id no longer resolves")
    func terminatedSessionIdNoLongerResolves() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()
        let principal = MCPLegacyTestSupport.principal(fingerprint: "alice")
        let (_, sessionId) = try await adapter.handleInitialize(
            params: MCPLegacyTestSupport.initializeParams(),
            principal: principal
        )
        await adapter.terminate(sessionId: sessionId)

        let error = await #expect(throws: MCPProtocolError.self) {
            _ = try await adapter.resolve(
                message: MCPLegacyTestSupport.request(method: "tools/list"),
                inbound: MCPLegacyTestSupport.inbound(principal: principal, sessionId: sessionId)
            )
        }

        #expect(error?.code == JsonRpcErrorCode.sessionNotFound)
    }

    @Test("Revoking a token terminates every session it owns and cancels their work")
    func revokingATokenTerminatesItsSessions() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()
        let tokenId = UUID()
        let principal = MCPLegacyTestSupport.principal(fingerprint: "alice", tokenId: tokenId)
        let (_, sessionId) = try await adapter.handleInitialize(
            params: MCPLegacyTestSupport.initializeParams(),
            principal: principal
        )
        let cancellation = MCPCancellationToken()
        await adapter.trackInFlight(sessionId: sessionId, requestId: .number(1), cancellation: cancellation)

        let terminated = await adapter.terminateSessions(ownedByTokenId: tokenId)

        #expect(terminated == [sessionId])
        let cancelled = await cancellation.isCancelled
        let reason = await cancellation.reason
        #expect(cancelled)
        #expect(reason == .credentialRevoked)
    }

    @Test("Shutting down terminates every legacy session")
    func shutdownTerminatesEverySession() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()
        for index in 0 ..< 3 {
            _ = try await adapter.handleInitialize(
                params: MCPLegacyTestSupport.initializeParams(clientName: "client-\(index)"),
                principal: MCPLegacyTestSupport.principal(fingerprint: "client-\(index)", tokenId: UUID())
            )
        }

        await adapter.shutdown()

        let sessions = await adapter.sessionCount()
        #expect(sessions == 0)
    }

    @Test("Session snapshots report the handshake and the in-flight count")
    func snapshotsReportTheHandshake() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()
        let principal = MCPLegacyTestSupport.principal(fingerprint: "alice", tokenId: UUID())
        let (_, sessionId) = try await adapter.handleInitialize(
            params: MCPLegacyTestSupport.initializeParams(clientName: "acme-cli"),
            principal: principal
        )
        await adapter.trackInFlight(sessionId: sessionId, requestId: .number(1), cancellation: MCPCancellationToken())

        let snapshots = await adapter.sessionSnapshots()

        #expect(snapshots.count == 1)
        #expect(snapshots.first?.id == sessionId)
        #expect(snapshots.first?.clientInfo?.name == "acme-cli")
        #expect(snapshots.first?.protocolVersion == .v20251125)
        #expect(snapshots.first?.owner.tokenId == principal.tokenId)
        #expect(snapshots.first?.inFlightRequestCount == 1)
    }

    @Test("Releasing an in-flight request clears it from the session")
    func releasingInFlightWorkClearsIt() async throws {
        let adapter = MCPLegacyTestSupport.makeAdapter()
        let principal = MCPLegacyTestSupport.principal(fingerprint: "alice")
        let (_, sessionId) = try await adapter.handleInitialize(
            params: MCPLegacyTestSupport.initializeParams(),
            principal: principal
        )
        await adapter.trackInFlight(sessionId: sessionId, requestId: .number(1), cancellation: MCPCancellationToken())

        await adapter.releaseInFlight(sessionId: sessionId, requestId: .number(1))

        let snapshots = await adapter.sessionSnapshots()
        #expect(snapshots.first?.inFlightRequestCount == 0)
    }

    @Test("Initialize, ping and logging/setLevel are the only legacy-only methods")
    func theLegacyOnlyMethodSetIsClosed() {
        #expect(MCPLegacyEraAdapter.legacyOnlyMethods == ["initialize", "ping", "logging/setLevel"])
        #expect(MCPLegacyEraAdapter.isLegacyOnly(method: "ping"))
        #expect(MCPLegacyEraAdapter.isLegacyOnly(method: "initialize"))
        #expect(MCPLegacyEraAdapter.isLegacyOnly(method: "logging/setLevel"))
        #expect(!MCPLegacyEraAdapter.isLegacyOnly(method: "tools/list"))
        #expect(!MCPLegacyEraAdapter.isLegacyOnly(method: "server/discover"))
    }

    @Test("Every legacy-only handler serves legacy clients and refuses modern ones")
    func everyLegacyOnlyHandlerServesLegacyClientsOnly() {
        let handlers = MCPLegacyEraAdapter.legacyOnlyHandlers()
        let methods = Set(handlers.map { type(of: $0).method })

        #expect(methods == MCPLegacyEraAdapter.legacyOnlyMethods)
        #expect(handlers.allSatisfy { type(of: $0).isAvailableToLegacyClients })
        #expect(handlers.allSatisfy { !type(of: $0).isAvailableToModernClients })
    }
}

actor LegacyEraTestClock: MCPClock {
    private struct PendingSleep {
        let dueAt: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private var currentDate: Date
    private var pending: [PendingSleep] = []

    init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        currentDate = start
    }

    func now() -> Date {
        currentDate
    }

    func sleep(for duration: Duration) async throws {
        let dueAt = currentDate.addingTimeInterval(Self.seconds(of: duration))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pending.append(PendingSleep(dueAt: dueAt, continuation: continuation))
        }
    }

    func advance(by duration: Duration) async {
        currentDate = currentDate.addingTimeInterval(Self.seconds(of: duration))
        let due = pending.filter { $0.dueAt <= currentDate }
        pending.removeAll { $0.dueAt <= currentDate }
        for sleep in due {
            sleep.continuation.resume()
        }
        await Task.yield()
    }

    private static func seconds(of duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1.0e18
    }
}

actor LegacyEraRecordingSink: MCPResponderSink {
    private(set) var jsonWrites: [(data: Data, status: HttpStatus)] = []
    private(set) var acceptedCount = 0
    private(set) var sseStreamCount = 0
    private(set) var sseFrames: [SseFrame] = []
    private(set) var closed = false

    func writeJson(_ data: Data, status: HttpStatus, extraHeaders: [(String, String)]) async {
        jsonWrites.append((data, status))
    }

    func writeAccepted() async {
        acceptedCount += 1
    }

    func beginSseStream() async {
        sseStreamCount += 1
    }

    func writeSseFrame(_ frame: SseFrame) async {
        sseFrames.append(frame)
    }

    func closeConnection() async {
        closed = true
    }

    func isClosed() async -> Bool {
        closed
    }
}

enum MCPLegacyTestSupport {
    static let receivedAt = Date(timeIntervalSince1970: 1_700_000_000)

    static func makeAdapter(
        policy: MCPLegacySessionPolicy = .standard,
        clock: any MCPClock = LegacyEraTestClock()
    ) -> MCPLegacyEraAdapter {
        MCPLegacyEraAdapter(store: MCPLegacySessionStore(policy: policy, clock: clock))
    }

    static func principal(
        fingerprint: String = "test-fp",
        tokenId: UUID? = nil,
        scopes: Set<MCPScope> = MCPScope.readWriteSet
    ) -> MCPPrincipal {
        MCPPrincipal(
            tokenFingerprint: fingerprint,
            tokenId: tokenId,
            scopes: scopes,
            metadata: MCPPrincipalMetadata(label: fingerprint, issuedAt: receivedAt, expiresAt: nil)
        )
    }

    static func inbound(
        principal: MCPPrincipal? = MCPLegacyTestSupport.principal(),
        sessionId: MCPLegacySessionId? = nil,
        transportProtocolVersion: String? = nil,
        clientAddress: MCPClientAddress = .loopback
    ) -> MCPInboundContext {
        MCPInboundContext(
            principal: principal,
            clientAddress: clientAddress,
            receivedAt: receivedAt,
            transportProtocolVersion: transportProtocolVersion,
            legacySessionId: sessionId
        )
    }

    static func request(
        id: JsonRpcId = .number(1),
        method: String,
        params: JsonValue? = nil
    ) -> JsonRpcMessage {
        .request(JsonRpcRequest(id: id, method: method, params: params))
    }

    static func modernParams(
        version: String = MCPProtocolVersion.latest.rawValue,
        clientName: String = "modern-client",
        capabilities: JsonValue = .object([:])
    ) -> JsonValue {
        .object([
            "_meta": .object([
                MCPMetaKeys.protocolVersion: .string(version),
                MCPMetaKeys.clientInfo: .object([
                    "name": .string(clientName),
                    "version": .string("1.0.0")
                ]),
                MCPMetaKeys.clientCapabilities: capabilities
            ])
        ])
    }

    static func initializeParams(
        version: String = MCPProtocolVersion.v20251125.rawValue,
        clientName: String = "acme-cli",
        clientVersion: String = "9.9.9",
        capabilities: JsonValue = .object([:])
    ) -> JsonValue {
        .object([
            "protocolVersion": .string(version),
            "clientInfo": .object([
                "name": .string(clientName),
                "version": .string(clientVersion)
            ]),
            "capabilities": capabilities
        ])
    }

    static func legacyMeta(
        version: MCPProtocolVersion = .v20251125,
        clientName: String = "acme-cli"
    ) throws -> MCPRequestMeta {
        try MCPRequestMeta.synthesizedLegacy(
            protocolVersion: version,
            clientInfo: MCPImplementation(name: clientName, version: "9.9.9"),
            clientCapabilities: .none,
            params: nil
        )
    }

    static func modernMeta(version: MCPProtocolVersion = .latest) throws -> MCPRequestMeta {
        try MCPRequestMeta.decodeModern(params: modernParams(version: version.rawValue))
    }

    static func context(
        params: JsonValue? = nil,
        meta: MCPRequestMeta,
        requestId: JsonRpcId = .number(1)
    ) -> (MCPRequestContext, LegacyEraRecordingSink) {
        let sink = LegacyEraRecordingSink()
        let responder = MCPResponder(sink: sink, requestId: requestId)
        let context = MCPRequestContext(
            requestId: requestId,
            params: params,
            meta: meta,
            principal: principal(),
            responder: responder,
            progress: MCPProgressEmitter(meta: meta, responder: responder),
            cancellation: MCPCancellationToken(),
            clock: MCPSystemClock(),
            clientAddress: .loopback,
            receivedAt: receivedAt
        )
        return (context, sink)
    }
}
