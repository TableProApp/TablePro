import Foundation
@testable import TablePro
import TableProMCP
import TableProMCPTestSupport
import TableProPluginKit
import TableProTestSupport
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
    func aSupersededTokenKeepsItsInFlightRequestsUntilItsExpiry() async throws {
        let clock = MCPTestClock()
        let handler = StubTestHandler(behavior: .waitForCancellation)
        let dispatcher = MCPProtocolTestSupport.makeDispatcher(
            handlers: [handler],
            clock: clock,
            handlerTimeout: .seconds(86_400)
        )
        let request = MCPProtocolTestSupport.makeModernRequest(id: .number(12), method: StubTestHandler.method)
        let (exchange, sink) = MCPProtocolTestSupport.makeExchange(message: request, principal: alice)

        async let run: Void = dispatcher.dispatch(exchange)
        _ = await waitForInflight(dispatcher, count: 1)

        let tokenId = try #require(alice.tokenId)
        let expiry = await clock.now().addingTimeInterval(900)
        await dispatcher.cancelInflight(matchingTokenId: tokenId, at: expiry)

        #expect(await dispatcher.inflightCount() == 1)
        #expect(await sink.jsonWrites.isEmpty)

        try await waitUntil {
            await clock.advance(by: .seconds(60))
            return await dispatcher.inflightCount() == 0
        }
        #expect(await clock.now() >= expiry)

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

    @Test("The bridge's discover probe is not listed as a client, the client it carries is")
    func discoverProbeIsNotAClient() async throws {
        let dispatcher = MCPProtocolTestSupport.makeDispatcher(handlers: [DiscoverHandler(), StubToolsListHandler()])
        let bridge = Self.bridgePrincipal()

        let probe = Self.request(id: .string("tablepro-bridge-discover"), method: DiscoverHandler.method, clientName: "tablepro-mcp")
        let (probeExchange, probeSink) = MCPProtocolTestSupport.makeExchange(message: probe, principal: bridge, clientAddress: .localSocket)
        await dispatcher.dispatch(probeExchange)
        await probeSink.waitForCompletion()
        #expect(try await probeSink.successResult() != nil)
        #expect(await dispatcher.activityLedger.snapshot(now: MCPProtocolTestSupport.referenceDate).isEmpty)

        let list = Self.request(id: .number(2), method: StubToolsListHandler.method, clientName: "claude-ai")
        let (listExchange, listSink) = MCPProtocolTestSupport.makeExchange(message: list, principal: bridge, clientAddress: .localSocket)
        await dispatcher.dispatch(listExchange)
        await listSink.waitForCompletion()

        let entries = await dispatcher.activityLedger.snapshot(now: MCPProtocolTestSupport.referenceDate)
        #expect(entries.map(\.clientName) == ["claude-ai"])
        #expect(entries.first?.transport == .stdioBridge)
    }

    @Test("Ending one stdio client's requests leaves another stdio client's request on the same credential running")
    func cancellingOneClientSparesTheOther() async throws {
        let handler = StubTestHandler(behavior: .waitForCancellation)
        let dispatcher = MCPProtocolTestSupport.makeDispatcher(handlers: [handler])
        let bridge = Self.bridgePrincipal()
        let (cursorExchange, cursorSink) = MCPProtocolTestSupport.makeExchange(
            message: Self.request(id: .number(1), method: StubTestHandler.method, clientName: "cursor-vscode"),
            principal: bridge,
            clientAddress: .localSocket
        )
        let (zedExchange, zedSink) = MCPProtocolTestSupport.makeExchange(
            message: Self.request(id: .number(2), method: StubTestHandler.method, clientName: "Zed"),
            principal: bridge,
            clientAddress: .localSocket
        )

        async let cursorRun: Void = dispatcher.dispatch(cursorExchange)
        async let zedRun: Void = dispatcher.dispatch(zedExchange)
        #expect(await waitForInflight(dispatcher, count: 2) == 2)

        let entries = await dispatcher.activityLedger.snapshot(now: MCPProtocolTestSupport.referenceDate)
        let cursor = try #require(entries.first { $0.clientName == "cursor-vscode" })
        #expect(await dispatcher.cancelInflight(matchingClientId: cursor.id) == 1)

        await cursorSink.waitForCompletion()
        let cursorError = try #require(try await cursorSink.errorEnvelope())
        #expect(cursorError.code == JsonRpcErrorCode.requestCancelled)
        #expect(await dispatcher.inflightCount() == 1)
        #expect(await zedSink.jsonWrites.isEmpty)

        _ = await dispatcher.cancelAllInflight()
        await zedSink.waitForCompletion()
        _ = await cursorRun
        _ = await zedRun
    }

    @Test("Two stdio clients may use the same request id, and one's cancellation stops only its own request")
    func stdioClientsShareARequestIdWithoutCollapsing() async throws {
        let handler = StubTestHandler(behavior: .waitForCancellation)
        let dispatcher = MCPProtocolTestSupport.makeDispatcher(handlers: [handler])
        let bridge = Self.bridgePrincipal()
        let (cursorExchange, cursorSink) = MCPProtocolTestSupport.makeExchange(
            message: Self.request(id: .number(1), method: StubTestHandler.method, clientName: "cursor-vscode"),
            principal: bridge,
            clientAddress: .localSocket
        )
        let (zedExchange, zedSink) = MCPProtocolTestSupport.makeExchange(
            message: Self.request(id: .number(1), method: StubTestHandler.method, clientName: "Zed"),
            principal: bridge,
            clientAddress: .localSocket
        )

        async let cursorRun: Void = dispatcher.dispatch(cursorExchange)
        async let zedRun: Void = dispatcher.dispatch(zedExchange)
        #expect(await waitForInflight(dispatcher, count: 2) == 2)

        let cancel = JsonRpcMessage.notification(JsonRpcNotification(
            method: "notifications/cancelled",
            params: .object([
                "requestId": .int(1),
                "_meta": .object(MCPProtocolTestSupport.metaFields(clientName: "Zed"))
            ])
        ))
        let (cancelExchange, cancelSink) = MCPProtocolTestSupport.makeExchange(
            message: cancel,
            principal: bridge,
            clientAddress: .localSocket
        )
        await dispatcher.dispatch(cancelExchange)
        #expect(await cancelSink.acceptedCount == 1)

        await zedSink.waitForCompletion()
        let zedError = try #require(try await zedSink.errorEnvelope())
        #expect(zedError.code == JsonRpcErrorCode.requestCancelled)
        #expect(await dispatcher.inflightCount() == 1)
        #expect(await cursorSink.jsonWrites.isEmpty)

        _ = await dispatcher.cancelAllInflight()
        await cursorSink.waitForCompletion()
        _ = await cursorRun
        _ = await zedRun
    }

    @Test("A stdio cancellation that names no client stops nothing")
    func stdioCancellationWithoutAClientIsDropped() async throws {
        let handler = StubTestHandler(behavior: .waitForCancellation)
        let dispatcher = MCPProtocolTestSupport.makeDispatcher(handlers: [handler])
        let bridge = Self.bridgePrincipal()
        let (exchange, sink) = MCPProtocolTestSupport.makeExchange(
            message: Self.request(id: .number(4), method: StubTestHandler.method, clientName: "Zed"),
            principal: bridge,
            clientAddress: .localSocket
        )

        async let run: Void = dispatcher.dispatch(exchange)
        #expect(await waitForInflight(dispatcher, count: 1) == 1)

        let (cancelExchange, cancelSink) = MCPProtocolTestSupport.makeExchange(
            message: MCPProtocolTestSupport.makeNotification(
                method: "notifications/cancelled",
                params: .object(["requestId": .int(4)])
            ),
            principal: bridge,
            clientAddress: .localSocket
        )
        await dispatcher.dispatch(cancelExchange)
        #expect(await cancelSink.acceptedCount == 1)
        #expect(await dispatcher.inflightCount() == 1)
        #expect(await sink.jsonWrites.isEmpty)

        _ = await dispatcher.cancelAllInflight()
        await sink.waitForCompletion()
        _ = await run
    }

    @Test("A stdio cancellation sent with the renewed bridge credential stops the request the old one started")
    func stdioCancellationCrossesACredentialRotation() async throws {
        let handler = StubTestHandler(behavior: .waitForCancellation)
        let dispatcher = MCPProtocolTestSupport.makeDispatcher(handlers: [handler], handlerTimeout: .seconds(10))
        let (exchange, sink) = MCPProtocolTestSupport.makeExchange(
            message: Self.request(id: .number(3), method: StubTestHandler.method, clientName: "claude-code", bridgeInstance: "one"),
            principal: Self.bridgePrincipal(fingerprint: "a"),
            clientAddress: .localSocket
        )

        async let run: Void = dispatcher.dispatch(exchange)
        #expect(await waitForInflight(dispatcher, count: 1) == 1)

        let (cancelExchange, cancelSink) = MCPProtocolTestSupport.makeExchange(
            message: Self.cancellation(requestId: 3, clientName: "claude-code", bridgeInstance: "one"),
            principal: Self.bridgePrincipal(fingerprint: "b"),
            clientAddress: .localSocket
        )
        await dispatcher.dispatch(cancelExchange)
        #expect(await cancelSink.acceptedCount == 1)
        #expect(await dispatcher.inflightCount() == 0)

        _ = await dispatcher.cancelAllInflight()
        await sink.waitForCompletion()
        let error = try #require(try await sink.errorEnvelope())
        #expect(error.code == JsonRpcErrorCode.requestCancelled)
        _ = await run
    }

    @Test("A stdio cancellation without clientInfo stops the request that sent it, matched by bridge instance")
    func stdioCancellationWithoutClientInfo() async throws {
        let handler = StubTestHandler(behavior: .waitForCancellation)
        let dispatcher = MCPProtocolTestSupport.makeDispatcher(handlers: [handler], handlerTimeout: .seconds(10))
        let bridge = Self.bridgePrincipal()
        let (exchange, sink) = MCPProtocolTestSupport.makeExchange(
            message: Self.request(id: .number(3), method: StubTestHandler.method, clientName: "claude-code", bridgeInstance: "one"),
            principal: bridge,
            clientAddress: .localSocket
        )

        async let run: Void = dispatcher.dispatch(exchange)
        #expect(await waitForInflight(dispatcher, count: 1) == 1)

        let (otherSession, _) = MCPProtocolTestSupport.makeExchange(
            message: Self.cancellation(requestId: 3, clientName: nil, bridgeInstance: "two"),
            principal: bridge,
            clientAddress: .localSocket
        )
        await dispatcher.dispatch(otherSession)
        #expect(await dispatcher.inflightCount() == 1)

        let (cancelExchange, cancelSink) = MCPProtocolTestSupport.makeExchange(
            message: Self.cancellation(requestId: 3, clientName: nil, bridgeInstance: "one"),
            principal: bridge,
            clientAddress: .localSocket
        )
        await dispatcher.dispatch(cancelExchange)
        #expect(await cancelSink.acceptedCount == 1)
        #expect(await dispatcher.inflightCount() == 0)

        _ = await dispatcher.cancelAllInflight()
        await sink.waitForCompletion()
        let error = try #require(try await sink.errorEnvelope())
        #expect(error.code == JsonRpcErrorCode.requestCancelled)
        _ = await run
    }

    @Test("Sessions of one stdio client share a request id: a cancellation stops its own session, Disconnect ends them all")
    func sessionsOfOneStdioClientKeepTheirRequestsApart() async throws {
        let handler = StubTestHandler(behavior: .waitForCancellation)
        let dispatcher = MCPProtocolTestSupport.makeDispatcher(handlers: [handler], handlerTimeout: .seconds(10))
        let bridge = Self.bridgePrincipal()
        let (oneExchange, oneSink) = MCPProtocolTestSupport.makeExchange(
            message: Self.request(id: .number(1), method: StubTestHandler.method, clientName: "claude-code", bridgeInstance: "one"),
            principal: bridge,
            clientAddress: .localSocket
        )
        let (twoExchange, twoSink) = MCPProtocolTestSupport.makeExchange(
            message: Self.request(id: .number(1), method: StubTestHandler.method, clientName: "claude-code", bridgeInstance: "two"),
            principal: bridge,
            clientAddress: .localSocket
        )
        let (threeExchange, threeSink) = MCPProtocolTestSupport.makeExchange(
            message: Self.request(id: .number(1), method: StubTestHandler.method, clientName: "claude-code", bridgeInstance: "three"),
            principal: bridge,
            clientAddress: .localSocket
        )

        async let oneRun: Void = dispatcher.dispatch(oneExchange)
        async let twoRun: Void = dispatcher.dispatch(twoExchange)
        async let threeRun: Void = dispatcher.dispatch(threeExchange)
        #expect(await waitForInflight(dispatcher, count: 3) == 3)

        let entries = await dispatcher.activityLedger.snapshot(now: MCPProtocolTestSupport.referenceDate)
        #expect(entries.count == 1)
        let row = try #require(entries.first)

        let (cancelExchange, _) = MCPProtocolTestSupport.makeExchange(
            message: Self.cancellation(requestId: 1, clientName: "claude-code", bridgeInstance: "three"),
            principal: bridge,
            clientAddress: .localSocket
        )
        await dispatcher.dispatch(cancelExchange)
        #expect(await dispatcher.inflightCount() == 2)
        #expect(await oneSink.jsonWrites.isEmpty)
        #expect(await twoSink.jsonWrites.isEmpty)

        #expect(await dispatcher.cancelInflight(matchingClientId: row.id) == 2)
        #expect(await dispatcher.inflightCount() == 0)

        _ = await dispatcher.cancelAllInflight()
        for sink in [oneSink, twoSink, threeSink] {
            await sink.waitForCompletion()
            let error = try #require(try await sink.errorEnvelope())
            #expect(error.code == JsonRpcErrorCode.requestCancelled)
        }
        _ = await oneRun
        _ = await twoRun
        _ = await threeRun
    }

    private static func bridgePrincipal(fingerprint: String = "bridge") -> MCPPrincipal {
        MCPPrincipal(
            tokenFingerprint: fingerprint,
            tokenId: UUID(),
            scopes: MCPScope.readWriteSet,
            connectionAccess: .all,
            metadata: MCPPrincipalMetadata(
                label: MCPTokenStore.stdioBridgeTokenName,
                issuedAt: MCPProtocolTestSupport.referenceDate,
                expiresAt: nil,
                isBridgeCredential: true
            )
        )
    }

    private static func request(id: JsonRpcId, method: String, clientName: String, bridgeInstance: String? = nil) -> JsonRpcMessage {
        .request(JsonRpcRequest(id: id, method: method, params: .object(["_meta": .object(meta(clientName, bridgeInstance))])))
    }

    private static func cancellation(requestId: Int, clientName: String?, bridgeInstance: String?) -> JsonRpcMessage {
        .notification(JsonRpcNotification(
            method: "notifications/cancelled",
            params: .object(["requestId": .int(requestId), "_meta": .object(meta(clientName, bridgeInstance))])
        ))
    }

    private static func meta(_ clientName: String?, _ bridgeInstance: String?) -> [String: JsonValue] {
        var fields = MCPProtocolTestSupport.metaFields(clientName: clientName)
        if let bridgeInstance {
            fields[MCPMetaKeys.bridgeInstance] = .string(bridgeInstance)
        }
        return fields
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
