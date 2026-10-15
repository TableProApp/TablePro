import Foundation
@testable import TablePro
import TableProMCP
import TableProMCPTestSupport
import TableProPluginKit
import Testing

struct MCPProtocolDispatcherTests {
    private let alice = MCPProtocolTestSupport.makePrincipal(
        fingerprint: "alice",
        tokenId: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001"),
        scopes: [.toolsRead, .toolsWrite]
    )
    private let bob = MCPProtocolTestSupport.makePrincipal(
        fingerprint: "bob",
        tokenId: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002"),
        scopes: [.toolsRead, .toolsWrite]
    )

    @Test
    func unknownMethodIsMethodNotFoundWithHttpNotFound() async throws {
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: "unknown/method"),
            handlers: [StubTestHandler()]
        )

        let errorValue = try await sink.errorEnvelope()
        let error = try #require(errorValue)
        #expect(error.code == JsonRpcErrorCode.methodNotFound)
        #expect(error.code == -32_601)

        let status = await sink.firstJsonStatus()
        #expect(status?.code == 404)

        guard case .errorResponse(let envelope)? = try await sink.firstJsonMessage() else {
            Issue.record("Expected an error response")
            return
        }
        #expect(envelope.id == .number(1))
    }

    @Test
    func aRequestWithoutAPrincipalIsUnauthenticated() async throws {
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: StubTestHandler.method),
            handlers: [StubTestHandler()],
            principal: nil
        )

        let errorValue = try await sink.errorEnvelope()
        let error = try #require(errorValue)
        #expect(error.code == JsonRpcErrorCode.unauthenticated)

        let status = await sink.firstJsonStatus()
        #expect(status?.code == 401)

        let challenge = await sink.firstHeaderValue(named: "WWW-Authenticate")
        #expect(challenge != nil)
        #expect(challenge?.hasPrefix("Bearer") ?? false)
    }

    @Test
    func aMissingScopeIsRefusedWithAChallengeThatNamesTheScopes() async throws {
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: StubScopedHandler.method),
            handlers: [StubScopedHandler()],
            principal: MCPProtocolTestSupport.makePrincipal(scopes: [.toolsRead])
        )

        let errorValue = try await sink.errorEnvelope()
        let error = try #require(errorValue)
        #expect(error.code == JsonRpcErrorCode.forbidden)

        let status = await sink.firstJsonStatus()
        #expect(status?.code == 403)

        let challengeValue = await sink.firstHeaderValue(named: "WWW-Authenticate")
        let challenge = try #require(challengeValue)
        #expect(challenge.contains("error=\"insufficient_scope\""))
        #expect(challenge.contains("scope=\"admin tools:write\""))

        let required = error.data?["requiredScopes"]?.arrayValue?.compactMap(\.stringValue)
        #expect(required == ["admin", "tools:write"])
    }

    @Test
    func aPartiallyScopedPrincipalStillLearnsWhichScopeIsMissing() async throws {
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: StubScopedHandler.method),
            handlers: [StubScopedHandler()],
            principal: MCPProtocolTestSupport.makePrincipal(scopes: [.toolsRead, .toolsWrite])
        )

        let challengeValue = await sink.firstHeaderValue(named: "WWW-Authenticate")
        let challenge = try #require(challengeValue)
        #expect(challenge.contains("admin"))
    }

    @Test
    func aHandlerThatFailsNeverLeaksTheConnectionDetailsItFailedOn() async throws {
        let secret = "postgres://root:hunter2@db.internal:5432/app"
        let handler = StubTestHandler(
            behavior: .failDriver(StubDriverError(detail: "FATAL: could not connect to \(secret)"))
        )
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: StubTestHandler.method),
            handlers: [handler]
        )

        let errorValue = try await sink.errorEnvelope()
        let error = try #require(errorValue)
        #expect(error.code == JsonRpcErrorCode.internalError)

        let body = await sink.firstJsonBodyText()
        for leak in ["db.internal", "5432", "root", "hunter2", "postgres://"] {
            #expect(!body.contains(leak), "response body leaked \(leak)")
        }
    }

    @Test
    func aProtocolErrorFromAHandlerIsPassedThroughUnchanged() async throws {
        let handler = StubTestHandler(behavior: .failProtocol(.invalidParams(detail: "table is required")))
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: StubTestHandler.method),
            handlers: [handler]
        )

        let errorValue = try await sink.errorEnvelope()
        let error = try #require(errorValue)
        #expect(error.code == JsonRpcErrorCode.invalidParams)

        let status = await sink.firstJsonStatus()
        #expect(status?.code == 400)
    }

    @Test
    func twoPrincipalsMayShareTheSameRequestIdWithoutCollapsing() async throws {
        let handler = StubTestHandler(behavior: .waitForCancellation)
        let dispatcher = MCPProtocolTestSupport.makeDispatcher(handlers: [handler])
        let request = MCPProtocolTestSupport.makeModernRequest(id: .number(1), method: StubTestHandler.method)
        let (aliceExchange, aliceSink) = MCPProtocolTestSupport.makeExchange(message: request, principal: alice)
        let (bobExchange, bobSink) = MCPProtocolTestSupport.makeExchange(message: request, principal: bob)

        async let aliceRun: Void = dispatcher.dispatch(aliceExchange)
        async let bobRun: Void = dispatcher.dispatch(bobExchange)

        let inflight = await waitForInflight(dispatcher, count: 2)
        #expect(inflight == 2)

        let cancelledAlice = await dispatcher.cancel(
            requestId: .number(1),
            principal: alice,
            reason: .clientRequested("stop")
        )
        #expect(cancelledAlice)
        await aliceSink.waitForCompletion()

        let aliceErrorValue = try await aliceSink.errorEnvelope()
        let aliceError = try #require(aliceErrorValue)
        #expect(aliceError.code == JsonRpcErrorCode.requestCancelled)

        let bobWrites = await bobSink.jsonWrites.count
        #expect(bobWrites == 0)

        let stillInflight = await dispatcher.inflightCount()
        #expect(stillInflight == 1)

        let cancelledBob = await dispatcher.cancel(
            requestId: .number(1),
            principal: bob,
            reason: .clientRequested(nil)
        )
        #expect(cancelledBob)
        await bobSink.waitForCompletion()
        _ = await aliceRun
        _ = await bobRun
    }

    @Test
    func anInFlightEntryIsReleasedWhenTheHandlerReturns() async throws {
        let dispatcher = MCPProtocolTestSupport.makeDispatcher(handlers: [StubTestHandler()])
        let (exchange, sink) = MCPProtocolTestSupport.makeExchange(
            message: MCPProtocolTestSupport.makeModernRequest(method: StubTestHandler.method),
            principal: alice
        )

        await dispatcher.dispatch(exchange)
        await sink.waitForCompletion()

        let inflight = await dispatcher.inflightCount()
        #expect(inflight == 0)
    }

    @Test
    func aModernResultDeclaresItsTypeAndTheServerIdentity() async throws {
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: StubTestHandler.method),
            handlers: [StubTestHandler()]
        )

        let resultValue = try await sink.successResult()
        let result = try #require(resultValue)
        #expect(result["resultType"]?.stringValue == "complete")
        #expect(result["ok"]?.boolValue == true)
        #expect(result["_meta"]?[MCPMetaKeys.serverInfo]?["name"]?.stringValue == "tablepro")
        #expect(result["serverInfo"] == nil)

        let status = await sink.firstJsonStatus()
        #expect(status?.code == 200)
    }

    @Test
    func aModernRequestWithoutMetaIsInvalidParams() async throws {
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeRequest(method: StubTestHandler.method, params: .object([:])),
            handlers: [StubTestHandler()]
        )

        let errorValue = try await sink.errorEnvelope()
        let error = try #require(errorValue)
        #expect(error.code == JsonRpcErrorCode.invalidParams)

        let status = await sink.firstJsonStatus()
        #expect(status?.code == 400)
    }

    @Test
    func anUnsupportedProtocolVersionIsRefusedBeforeTheHandlerRuns() async throws {
        let handler = StubTestHandler()
        let request = MCPProtocolTestSupport.makeModernRequest(
            method: StubTestHandler.method,
            protocolVersion: MCPProtocolVersion("2025-03-26")
        )
        let sink = try await dispatch(request, handlers: [handler])

        let errorValue = try await sink.errorEnvelope()
        let error = try #require(errorValue)
        #expect(error.code == JsonRpcErrorCode.unsupportedProtocolVersion)
        #expect(error.data?["requested"]?.stringValue == "2025-03-26")

        let started = await handler.started.value()
        #expect(!started)
    }

    @Test
    func aLegacyClientIsRefusedAModernOnlyMethod() async throws {
        let adapter = MCPLegacyEraAdapter()
        let sessionId = try await establishLegacySession(adapter: adapter, principal: alice)
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeRequest(method: StubModernOnlyHandler.method),
            handlers: [StubModernOnlyHandler()],
            principal: alice,
            legacyAdapter: adapter,
            legacySessionId: sessionId
        )

        let errorValue = try await sink.errorEnvelope()
        let error = try #require(errorValue)
        #expect(error.code == JsonRpcErrorCode.methodNotFound)

        let status = await sink.firstJsonStatus()
        #expect(status?.code == 404)
    }

    @Test
    func aModernClientReachesAModernOnlyMethod() async throws {
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: StubModernOnlyHandler.method),
            handlers: [StubModernOnlyHandler()]
        )

        let resultValue = try await sink.successResult()
        let result = try #require(resultValue)
        #expect(result["resultType"]?.stringValue == "complete")
    }

    @Test
    func aLegacyResultCarriesNoModernEnvelopeFields() async throws {
        let adapter = MCPLegacyEraAdapter()
        let sessionId = try await establishLegacySession(adapter: adapter, principal: alice)
        let handler = StubToolsListHandler(
            behavior: .returning(.complete(["tools": .array([])], cacheHint: .privateFor(seconds: 300)))
        )
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeRequest(method: StubToolsListHandler.method),
            handlers: [handler],
            principal: alice,
            legacyAdapter: adapter,
            legacySessionId: sessionId
        )

        let resultValue = try await sink.successResult()
        let result = try #require(resultValue)
        #expect(result["tools"] != nil)
        #expect(result["resultType"] == nil)
        #expect(result["ttlMs"] == nil)
        #expect(result["cacheScope"] == nil)
        #expect(result["_meta"] == nil)
    }

    @Test
    func aLegacyInitializeIsAnsweredWithoutAModernEnvelope() async throws {
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeRequest(
                method: "initialize",
                params: .object([
                    "protocolVersion": .string(MCPProtocolVersion.v20251125.rawValue),
                    "capabilities": .object([:]),
                    "clientInfo": .object(["name": .string("OldClient"), "version": .string("0.9")])
                ])
            ),
            handlers: [StubTestHandler()]
        )

        let resultValue = try await sink.successResult()
        let result = try #require(resultValue)
        #expect(result["protocolVersion"]?.stringValue == MCPProtocolVersion.v20251125.rawValue)
        #expect(result["serverInfo"] != nil)
        #expect(result["resultType"] == nil)
    }

    @Test
    func aLegacyInitializeForAModernVersionIsRefused() async throws {
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeRequest(
                method: "initialize",
                params: .object(["protocolVersion": .string(MCPProtocolVersion.latest.rawValue)])
            ),
            handlers: [StubTestHandler()]
        )

        let errorValue = try await sink.errorEnvelope()
        let error = try #require(errorValue)
        #expect(error.code == JsonRpcErrorCode.unsupportedProtocolVersion)
    }

    @Test
    func aCacheableMethodWithoutAHintIsReportedAsImmediatelyStale() async throws {
        let handler = StubToolsListHandler(behavior: .returning(.complete(["tools": .array([])])))
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: StubToolsListHandler.method),
            handlers: [handler]
        )

        let resultValue = try await sink.successResult()
        let result = try #require(resultValue)
        #expect(result["ttlMs"]?.intValue == 0)
        #expect(result["cacheScope"]?.stringValue == "private")
    }

    @Test
    func aCacheableMethodKeepsTheHintItReturned() async throws {
        let handler = StubToolsListHandler(
            behavior: .returning(.complete(["tools": .array([])], cacheHint: .publicFor(seconds: 300)))
        )
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: StubToolsListHandler.method),
            handlers: [handler]
        )

        let resultValue = try await sink.successResult()
        let result = try #require(resultValue)
        #expect(result["ttlMs"]?.intValue == 300_000)
        #expect(result["cacheScope"]?.stringValue == "public")
    }

    @Test
    func anUncacheableMethodNeverCarriesCacheFields() async throws {
        let handler = StubToolsCallHandler(
            behavior: .returning(.complete(["content": .array([])], cacheHint: .publicFor(seconds: 300)))
        )
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: StubToolsCallHandler.method),
            handlers: [handler]
        )

        let resultValue = try await sink.successResult()
        let result = try #require(resultValue)
        #expect(result["ttlMs"] == nil)
        #expect(result["cacheScope"] == nil)
        #expect(result["resultType"]?.stringValue == "complete")
    }

    @Test
    func aRetriedRequestCarryingInputResponsesIsNotCacheable() async throws {
        let handler = StubResourcesReadHandler(
            behavior: .returning(.complete(["contents": .array([])], cacheHint: .privateFor(seconds: 60)))
        )
        let request = MCPProtocolTestSupport.makeModernRequest(
            method: StubResourcesReadHandler.method,
            payload: ["inputResponses": .array([.object(["value": .string("yes")])])]
        )
        let sink = try await dispatch(request, handlers: [handler])

        let resultValue = try await sink.successResult()
        let result = try #require(resultValue)
        #expect(result["ttlMs"]?.intValue == 0)
        #expect(result["cacheScope"]?.stringValue == "private")
    }

    @Test
    func anInterimResultCarriesNoCacheHint() async throws {
        let interim = MCPResult(kind: .inputRequired, payload: ["inputRequests": .array([])])
        let handler = StubResourcesReadHandler(behavior: .returning(interim))
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: StubResourcesReadHandler.method),
            handlers: [handler]
        )

        let resultValue = try await sink.successResult()
        let result = try #require(resultValue)
        #expect(result["resultType"]?.stringValue == "input_required")
        #expect(result["ttlMs"] == nil)
        #expect(result["cacheScope"] == nil)
    }

    @Test
    func aMethodThatMayNotAskForInputCannotReturnAnInterimResult() async throws {
        let interim = MCPResult(kind: .inputRequired, payload: [:])
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: StubTestHandler.method),
            handlers: [StubTestHandler(behavior: .returning(interim))]
        )

        let errorValue = try await sink.errorEnvelope()
        let error = try #require(errorValue)
        #expect(error.code == JsonRpcErrorCode.internalError)
    }

    @Test
    func aHandlerThatOverrunsItsDeadlineIsTimedOut() async throws {
        let gate = ReleaseGate()
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: StubTestHandler.method),
            handlers: [StubTestHandler(behavior: .blockUntilReleased(gate))],
            handlerTimeout: .milliseconds(60),
            disconnectPollInterval: .milliseconds(20)
        )
        await gate.release()

        let errorValue = try await sink.errorEnvelope()
        let error = try #require(errorValue)
        #expect(error.code == JsonRpcErrorCode.requestTimeout)
        #expect(error.code == -33_003)
    }

    @Test
    func closingTheStreamCancelsTheRequest() async throws {
        let gate = ReleaseGate()
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: StubTestHandler.method),
            handlers: [StubTestHandler(behavior: .blockUntilReleased(gate))],
            handlerTimeout: .seconds(30),
            disconnectPollInterval: .milliseconds(20),
            clientDisconnected: true
        )
        await gate.release()

        let errorValue = try await sink.errorEnvelope()
        let error = try #require(errorValue)
        #expect(error.code == JsonRpcErrorCode.requestCancelled)
        #expect(error.code == -33_002)
    }

    @Test
    func anUnknownNotificationIsAcknowledgedAndDropped() async throws {
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeNotification(method: "notifications/initialized"),
            handlers: [StubTestHandler()]
        )

        let accepted = await sink.acceptedCount
        let writes = await sink.jsonWrites.count
        #expect(accepted == 1)
        #expect(writes == 0)
    }

    @Test
    func aResponseMessageIsIgnoredAndAcknowledged() async throws {
        let response = JsonRpcMessage.successResponse(JsonRpcSuccessResponse(id: .number(1), result: .object([:])))
        let sink = try await dispatch(response, handlers: [StubTestHandler()])

        let accepted = await sink.acceptedCount
        #expect(accepted == 1)
    }

    @Test
    func aCancellationNotificationCancelsTheMatchingRequest() async throws {
        let handler = StubTestHandler(behavior: .waitForCancellation)
        let dispatcher = MCPProtocolTestSupport.makeDispatcher(handlers: [handler])
        let request = MCPProtocolTestSupport.makeModernRequest(id: .number(99), method: StubTestHandler.method)
        let (exchange, sink) = MCPProtocolTestSupport.makeExchange(message: request, principal: alice)

        async let run: Void = dispatcher.dispatch(exchange)
        _ = await waitForInflight(dispatcher, count: 1)

        let (cancelExchange, cancelSink) = MCPProtocolTestSupport.makeExchange(
            message: MCPProtocolTestSupport.makeNotification(
                method: "notifications/cancelled",
                params: .object(["requestId": .int(99), "reason": .string("user stopped")])
            ),
            principal: alice
        )
        await dispatcher.dispatch(cancelExchange)
        await sink.waitForCompletion()

        let errorValue = try await sink.errorEnvelope()
        let error = try #require(errorValue)
        #expect(error.code == JsonRpcErrorCode.requestCancelled)

        let accepted = await cancelSink.acceptedCount
        #expect(accepted == 1)
        _ = await run
    }

    @Test
    func aCancellationFromAnotherPrincipalIsIgnored() async throws {
        let handler = StubTestHandler(behavior: .waitForCancellation)
        let dispatcher = MCPProtocolTestSupport.makeDispatcher(handlers: [handler])
        let request = MCPProtocolTestSupport.makeModernRequest(id: .number(5), method: StubTestHandler.method)
        let (exchange, sink) = MCPProtocolTestSupport.makeExchange(message: request, principal: alice)

        async let run: Void = dispatcher.dispatch(exchange)
        _ = await waitForInflight(dispatcher, count: 1)

        let (cancelExchange, _) = MCPProtocolTestSupport.makeExchange(
            message: MCPProtocolTestSupport.makeNotification(
                method: "notifications/cancelled",
                params: .object(["requestId": .int(5)])
            ),
            principal: bob
        )
        await dispatcher.dispatch(cancelExchange)

        let stillInflight = await dispatcher.inflightCount()
        #expect(stillInflight == 1)

        let writes = await sink.jsonWrites.count
        #expect(writes == 0)

        _ = await dispatcher.cancelAllInflight()
        await sink.waitForCompletion()
        _ = await run
    }

    @Test
    func revokingATokenCancelsItsInFlightRequests() async throws {
        let handler = StubTestHandler(behavior: .waitForCancellation)
        let dispatcher = MCPProtocolTestSupport.makeDispatcher(handlers: [handler])
        let request = MCPProtocolTestSupport.makeModernRequest(id: .number(11), method: StubTestHandler.method)
        let (exchange, sink) = MCPProtocolTestSupport.makeExchange(message: request, principal: alice)

        async let run: Void = dispatcher.dispatch(exchange)
        _ = await waitForInflight(dispatcher, count: 1)

        let tokenId = try #require(alice.tokenId)
        let cancelled = await dispatcher.cancelInflight(matchingTokenId: tokenId)
        #expect(cancelled == 1)

        await sink.waitForCompletion()
        let errorValue = try await sink.errorEnvelope()
        let error = try #require(errorValue)
        #expect(error.code == JsonRpcErrorCode.requestCancelled)
        _ = await run
    }

    @Test
    func anInputRequiredSignalReachesTheClientAsAnInputRequiredResult() async throws {
        let signal = MCPInputRequired(
            inputRequests: [
                MCPElicitationRequest.approval(
                    key: "approve_connection",
                    message: "Allow this client to access 'Sales' (PostgreSQL)?",
                    detail: "PostgreSQL"
                )
            ],
            requestState: "sealed-state"
        )
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: StubToolsCallHandler.method),
            handlers: [StubToolsCallHandler(behavior: .requiringInput(signal))]
        )

        let envelope = try await sink.errorEnvelope()
        #expect(envelope == nil, "A consent question is not a failure")

        let resultValue = try await sink.successResult()
        let result = try #require(resultValue)
        #expect(result["resultType"]?.stringValue == "input_required")
        #expect(result["requestState"]?.stringValue == "sealed-state")
        #expect(result["inputRequests"]?["approve_connection"] != nil)
    }

    private func dispatch(
        _ message: JsonRpcMessage,
        handlers: [any MCPMethodHandler],
        principal: MCPPrincipal? = MCPProtocolTestSupport.makePrincipal(),
        legacyAdapter: MCPLegacyEraAdapter = MCPLegacyEraAdapter(),
        legacySessionId: MCPLegacySessionId? = nil,
        handlerTimeout: Duration = .seconds(330),
        disconnectPollInterval: Duration = .seconds(60),
        clientDisconnected: Bool = false
    ) async throws -> RecordingResponderSink {
        let dispatcher = MCPProtocolTestSupport.makeDispatcher(
            handlers: handlers,
            legacyAdapter: legacyAdapter,
            handlerTimeout: handlerTimeout,
            disconnectPollInterval: disconnectPollInterval
        )
        let (exchange, sink) = MCPProtocolTestSupport.makeExchange(
            message: message,
            principal: principal,
            legacySessionId: legacySessionId
        )
        if clientDisconnected {
            await sink.disconnectClient()
        }
        await dispatcher.dispatch(exchange)
        await sink.waitForCompletion()
        return sink
    }

    private func establishLegacySession(
        adapter: MCPLegacyEraAdapter,
        principal: MCPPrincipal
    ) async throws -> MCPLegacySessionId {
        let (_, sessionId) = try await adapter.handleInitialize(
            params: .object([
                "protocolVersion": .string(MCPProtocolVersion.v20251125.rawValue),
                "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("OldClient"), "version": .string("0.9")])
            ]),
            principal: principal
        )
        return sessionId
    }

    private func waitForInflight(_ dispatcher: MCPProtocolDispatcher, count: Int) async -> Int {
        for _ in 0 ..< 400 {
            let current = await dispatcher.inflightCount()
            if current >= count { return current }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await dispatcher.inflightCount()
    }
}

struct MCPCancelledNotificationFuzzTests {
    private static let longIdentifier = String(repeating: "a", count: 8_192)

    private let principal = MCPProtocolTestSupport.makePrincipal(fingerprint: "fuzz")

    private static let hostileRequestIds = [
        "1e300",
        "-1e300",
        "9223372036854775808",
        "-9223372036854775809",
        "1.5",
        "-0.5",
        "null",
        "{}",
        "{\"id\": 1}",
        "[]",
        "[1, 2, 3]",
        "true",
        "false"
    ]

    @Test
    func aHostileRequestIdIsRejectedInsteadOfTrapping() throws {
        for raw in Self.hostileRequestIds {
            let params = try MCPProtocolTestSupport.jsonValue(fromJson: "{\"requestId\": \(raw)}")
            #expect(MCPProtocolDispatcher.cancellationRequestId(in: params) == nil,
                "requestId \(raw) should not resolve to an in-flight key")
        }
    }

    @Test
    func aUsableRequestIdIsResolved() throws {
        let cases: [(String, JsonRpcId)] = [
            ("0", .number(0)),
            ("99", .number(99)),
            ("-99", .number(-99)),
            ("9223372036854775807", .number(9_223_372_036_854_775_807)),
            ("\"req-1\"", .string("req-1")),
            ("\"\(Self.longIdentifier)\"", .string(Self.longIdentifier))
        ]

        for (raw, expected) in cases {
            let params = try MCPProtocolTestSupport.jsonValue(fromJson: "{\"requestId\": \(raw)}")
            #expect(MCPProtocolDispatcher.cancellationRequestId(in: params) == expected, "requestId \(raw)")
        }
    }

    @Test
    func aMissingOrMalformedParamsObjectIsRejected() throws {
        #expect(MCPProtocolDispatcher.cancellationRequestId(in: nil) == nil)
        #expect(MCPProtocolDispatcher.cancellationRequestId(in: .object([:])) == nil)
        #expect(MCPProtocolDispatcher.cancellationRequestId(in: .string("nope")) == nil)
        #expect(MCPProtocolDispatcher.cancellationRequestId(in: .array([.int(1)])) == nil)
        #expect(MCPProtocolDispatcher.cancellationRequestId(in: .object(["requestId": .null])) == nil)
    }

    @Test
    func hostileCancellationsAreAcknowledgedAndLeaveTheRequestRunning() async throws {
        let handler = StubTestHandler(behavior: .waitForCancellation)
        let dispatcher = MCPProtocolTestSupport.makeDispatcher(handlers: [handler])
        let request = MCPProtocolTestSupport.makeModernRequest(
            id: .string(Self.longIdentifier),
            method: StubTestHandler.method
        )
        let (exchange, sink) = MCPProtocolTestSupport.makeExchange(message: request, principal: principal)

        async let run: Void = dispatcher.dispatch(exchange)
        _ = await waitForInflight(dispatcher)

        for raw in Self.hostileRequestIds {
            let params = try MCPProtocolTestSupport.jsonValue(fromJson: "{\"requestId\": \(raw)}")
            let acknowledged = await sendCancellation(params: params, to: dispatcher)
            #expect(acknowledged == 1, "cancellation with requestId \(raw) was not acknowledged")

            let inflight = await dispatcher.inflightCount()
            #expect(inflight == 1, "cancellation with requestId \(raw) disturbed an unrelated request")
        }

        let unmatched = await sendCancellation(
            params: .object(["requestId": .string("some-other-request")]),
            to: dispatcher
        )
        #expect(unmatched == 1)

        let writes = await sink.jsonWrites.count
        #expect(writes == 0)

        let acknowledged = await sendCancellation(
            params: .object(["requestId": .string(Self.longIdentifier), "reason": .string("user stopped")]),
            to: dispatcher
        )
        #expect(acknowledged == 1)

        await sink.waitForCompletion()
        let errorValue = try await sink.errorEnvelope()
        let error = try #require(errorValue)
        #expect(error.code == JsonRpcErrorCode.requestCancelled)

        let remaining = await dispatcher.inflightCount()
        #expect(remaining == 0)
        _ = await run
    }

    @Test
    func aCancellationWithoutAPrincipalIsDroppedButStillAcknowledged() async throws {
        let dispatcher = MCPProtocolTestSupport.makeDispatcher(handlers: [StubTestHandler()])
        let (exchange, sink) = MCPProtocolTestSupport.makeExchange(
            message: MCPProtocolTestSupport.makeNotification(
                method: "notifications/cancelled",
                params: .object(["requestId": .int(1)])
            ),
            principal: nil
        )

        await dispatcher.dispatch(exchange)

        let accepted = await sink.acceptedCount
        #expect(accepted == 1)
    }

    private func sendCancellation(params: JsonValue, to dispatcher: MCPProtocolDispatcher) async -> Int {
        let (exchange, sink) = MCPProtocolTestSupport.makeExchange(
            message: MCPProtocolTestSupport.makeNotification(method: "notifications/cancelled", params: params),
            principal: principal
        )
        await dispatcher.dispatch(exchange)
        return await sink.acceptedCount
    }

    private func waitForInflight(_ dispatcher: MCPProtocolDispatcher) async -> Int {
        for _ in 0 ..< 400 {
            let current = await dispatcher.inflightCount()
            if current >= 1 { return current }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await dispatcher.inflightCount()
    }
}
