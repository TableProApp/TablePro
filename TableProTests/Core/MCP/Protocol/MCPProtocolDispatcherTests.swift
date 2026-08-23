import Foundation
import TableProPluginKit
@testable import TablePro
import XCTest

final class MCPProtocolDispatcherTests: XCTestCase {
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

    func testUnknownMethodIsMethodNotFoundWithHttpNotFound() async throws {
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: "unknown/method"),
            handlers: [StubTestHandler()]
        )

        let errorValue = try await sink.errorEnvelope()
        let error = try XCTUnwrap(errorValue)
        XCTAssertEqual(error.code, JsonRpcErrorCode.methodNotFound)
        XCTAssertEqual(error.code, -32_601)

        let status = await sink.firstJsonStatus()
        XCTAssertEqual(status?.code, 404)

        guard case .errorResponse(let envelope)? = try await sink.firstJsonMessage() else {
            XCTFail("Expected an error response")
            return
        }
        XCTAssertEqual(envelope.id, .number(1))
    }

    func testARequestWithoutAPrincipalIsUnauthenticated() async throws {
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: StubTestHandler.method),
            handlers: [StubTestHandler()],
            principal: nil
        )

        let errorValue = try await sink.errorEnvelope()
        let error = try XCTUnwrap(errorValue)
        XCTAssertEqual(error.code, JsonRpcErrorCode.unauthenticated)

        let status = await sink.firstJsonStatus()
        XCTAssertEqual(status?.code, 401)

        let challenge = await sink.firstHeaderValue(named: "WWW-Authenticate")
        XCTAssertNotNil(challenge)
        XCTAssertTrue(challenge?.hasPrefix("Bearer") ?? false)
    }

    func testAMissingScopeIsRefusedWithAChallengeThatNamesTheScopes() async throws {
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: StubScopedHandler.method),
            handlers: [StubScopedHandler()],
            principal: MCPProtocolTestSupport.makePrincipal(scopes: [.toolsRead])
        )

        let errorValue = try await sink.errorEnvelope()
        let error = try XCTUnwrap(errorValue)
        XCTAssertEqual(error.code, JsonRpcErrorCode.forbidden)

        let status = await sink.firstJsonStatus()
        XCTAssertEqual(status?.code, 403)

        let challengeValue = await sink.firstHeaderValue(named: "WWW-Authenticate")
        let challenge = try XCTUnwrap(challengeValue)
        XCTAssertTrue(challenge.contains("error=\"insufficient_scope\""))
        XCTAssertTrue(challenge.contains("scope=\"admin tools:write\""))

        let required = error.data?["requiredScopes"]?.arrayValue?.compactMap(\.stringValue)
        XCTAssertEqual(required, ["admin", "tools:write"])
    }

    func testAPartiallyScopedPrincipalStillLearnsWhichScopeIsMissing() async throws {
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: StubScopedHandler.method),
            handlers: [StubScopedHandler()],
            principal: MCPProtocolTestSupport.makePrincipal(scopes: [.toolsRead, .toolsWrite])
        )

        let challengeValue = await sink.firstHeaderValue(named: "WWW-Authenticate")
        let challenge = try XCTUnwrap(challengeValue)
        XCTAssertTrue(challenge.contains("admin"))
    }

    func testAHandlerThatFailsNeverLeaksTheConnectionDetailsItFailedOn() async throws {
        let secret = "postgres://root:hunter2@db.internal:5432/app"
        let handler = StubTestHandler(
            behavior: .failDriver(StubDriverError(detail: "FATAL: could not connect to \(secret)"))
        )
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: StubTestHandler.method),
            handlers: [handler]
        )

        let errorValue = try await sink.errorEnvelope()
        let error = try XCTUnwrap(errorValue)
        XCTAssertEqual(error.code, JsonRpcErrorCode.internalError)

        let body = await sink.firstJsonBodyText()
        for leak in ["db.internal", "5432", "root", "hunter2", "postgres://"] {
            XCTAssertFalse(body.contains(leak), "response body leaked \(leak)")
        }
    }

    func testAProtocolErrorFromAHandlerIsPassedThroughUnchanged() async throws {
        let handler = StubTestHandler(behavior: .failProtocol(.invalidParams(detail: "table is required")))
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: StubTestHandler.method),
            handlers: [handler]
        )

        let errorValue = try await sink.errorEnvelope()
        let error = try XCTUnwrap(errorValue)
        XCTAssertEqual(error.code, JsonRpcErrorCode.invalidParams)

        let status = await sink.firstJsonStatus()
        XCTAssertEqual(status?.code, 400)
    }

    func testTwoPrincipalsMayShareTheSameRequestIdWithoutCollapsing() async throws {
        let handler = StubTestHandler(behavior: .waitForCancellation)
        let dispatcher = MCPProtocolTestSupport.makeDispatcher(handlers: [handler])
        let request = MCPProtocolTestSupport.makeModernRequest(id: .number(1), method: StubTestHandler.method)
        let (aliceExchange, aliceSink) = MCPProtocolTestSupport.makeExchange(message: request, principal: alice)
        let (bobExchange, bobSink) = MCPProtocolTestSupport.makeExchange(message: request, principal: bob)

        async let aliceRun: Void = dispatcher.dispatch(aliceExchange)
        async let bobRun: Void = dispatcher.dispatch(bobExchange)

        let inflight = await waitForInflight(dispatcher, count: 2)
        XCTAssertEqual(inflight, 2)

        let cancelledAlice = await dispatcher.cancel(
            requestId: .number(1),
            principal: alice,
            reason: .clientRequested("stop")
        )
        XCTAssertTrue(cancelledAlice)
        await aliceSink.waitForCompletion()

        let aliceErrorValue = try await aliceSink.errorEnvelope()
        let aliceError = try XCTUnwrap(aliceErrorValue)
        XCTAssertEqual(aliceError.code, JsonRpcErrorCode.requestCancelled)

        let bobWrites = await bobSink.jsonWrites.count
        XCTAssertEqual(bobWrites, 0)

        let stillInflight = await dispatcher.inflightCount()
        XCTAssertEqual(stillInflight, 1)

        let cancelledBob = await dispatcher.cancel(
            requestId: .number(1),
            principal: bob,
            reason: .clientRequested(nil)
        )
        XCTAssertTrue(cancelledBob)
        await bobSink.waitForCompletion()
        _ = await aliceRun
        _ = await bobRun
    }

    func testAnInFlightEntryIsReleasedWhenTheHandlerReturns() async throws {
        let dispatcher = MCPProtocolTestSupport.makeDispatcher(handlers: [StubTestHandler()])
        let (exchange, sink) = MCPProtocolTestSupport.makeExchange(
            message: MCPProtocolTestSupport.makeModernRequest(method: StubTestHandler.method),
            principal: alice
        )

        await dispatcher.dispatch(exchange)
        await sink.waitForCompletion()

        let inflight = await dispatcher.inflightCount()
        XCTAssertEqual(inflight, 0)
    }

    func testAModernResultDeclaresItsTypeAndTheServerIdentity() async throws {
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: StubTestHandler.method),
            handlers: [StubTestHandler()]
        )

        let resultValue = try await sink.successResult()
        let result = try XCTUnwrap(resultValue)
        XCTAssertEqual(result["resultType"]?.stringValue, "complete")
        XCTAssertEqual(result["ok"]?.boolValue, true)
        XCTAssertEqual(result["_meta"]?[MCPMetaKeys.serverInfo]?["name"]?.stringValue, "tablepro")
        XCTAssertNil(result["serverInfo"])

        let status = await sink.firstJsonStatus()
        XCTAssertEqual(status?.code, 200)
    }

    func testAModernRequestWithoutMetaIsInvalidParams() async throws {
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeRequest(method: StubTestHandler.method, params: .object([:])),
            handlers: [StubTestHandler()]
        )

        let errorValue = try await sink.errorEnvelope()
        let error = try XCTUnwrap(errorValue)
        XCTAssertEqual(error.code, JsonRpcErrorCode.invalidParams)

        let status = await sink.firstJsonStatus()
        XCTAssertEqual(status?.code, 400)
    }

    func testAnUnsupportedProtocolVersionIsRefusedBeforeTheHandlerRuns() async throws {
        let handler = StubTestHandler()
        let request = MCPProtocolTestSupport.makeModernRequest(
            method: StubTestHandler.method,
            protocolVersion: MCPProtocolVersion("2025-03-26")
        )
        let sink = try await dispatch(request, handlers: [handler])

        let errorValue = try await sink.errorEnvelope()
        let error = try XCTUnwrap(errorValue)
        XCTAssertEqual(error.code, JsonRpcErrorCode.unsupportedProtocolVersion)
        XCTAssertEqual(error.data?["requested"]?.stringValue, "2025-03-26")

        let started = await handler.started.value()
        XCTAssertFalse(started)
    }

    func testALegacyClientIsRefusedAModernOnlyMethod() async throws {
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
        let error = try XCTUnwrap(errorValue)
        XCTAssertEqual(error.code, JsonRpcErrorCode.methodNotFound)

        let status = await sink.firstJsonStatus()
        XCTAssertEqual(status?.code, 404)
    }

    func testAModernClientReachesAModernOnlyMethod() async throws {
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: StubModernOnlyHandler.method),
            handlers: [StubModernOnlyHandler()]
        )

        let resultValue = try await sink.successResult()
        let result = try XCTUnwrap(resultValue)
        XCTAssertEqual(result["resultType"]?.stringValue, "complete")
    }

    func testALegacyResultCarriesNoModernEnvelopeFields() async throws {
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
        let result = try XCTUnwrap(resultValue)
        XCTAssertNotNil(result["tools"])
        XCTAssertNil(result["resultType"])
        XCTAssertNil(result["ttlMs"])
        XCTAssertNil(result["cacheScope"])
        XCTAssertNil(result["_meta"])
    }

    func testALegacyInitializeIsAnsweredWithoutAModernEnvelope() async throws {
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
        let result = try XCTUnwrap(resultValue)
        XCTAssertEqual(result["protocolVersion"]?.stringValue, MCPProtocolVersion.v20251125.rawValue)
        XCTAssertNotNil(result["serverInfo"])
        XCTAssertNil(result["resultType"])
    }

    func testALegacyInitializeForAModernVersionIsRefused() async throws {
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeRequest(
                method: "initialize",
                params: .object(["protocolVersion": .string(MCPProtocolVersion.latest.rawValue)])
            ),
            handlers: [StubTestHandler()]
        )

        let errorValue = try await sink.errorEnvelope()
        let error = try XCTUnwrap(errorValue)
        XCTAssertEqual(error.code, JsonRpcErrorCode.unsupportedProtocolVersion)
    }

    func testACacheableMethodWithoutAHintIsReportedAsImmediatelyStale() async throws {
        let handler = StubToolsListHandler(behavior: .returning(.complete(["tools": .array([])])))
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: StubToolsListHandler.method),
            handlers: [handler]
        )

        let resultValue = try await sink.successResult()
        let result = try XCTUnwrap(resultValue)
        XCTAssertEqual(result["ttlMs"]?.intValue, 0)
        XCTAssertEqual(result["cacheScope"]?.stringValue, "private")
    }

    func testACacheableMethodKeepsTheHintItReturned() async throws {
        let handler = StubToolsListHandler(
            behavior: .returning(.complete(["tools": .array([])], cacheHint: .publicFor(seconds: 300)))
        )
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: StubToolsListHandler.method),
            handlers: [handler]
        )

        let resultValue = try await sink.successResult()
        let result = try XCTUnwrap(resultValue)
        XCTAssertEqual(result["ttlMs"]?.intValue, 300_000)
        XCTAssertEqual(result["cacheScope"]?.stringValue, "public")
    }

    func testAnUncacheableMethodNeverCarriesCacheFields() async throws {
        let handler = StubToolsCallHandler(
            behavior: .returning(.complete(["content": .array([])], cacheHint: .publicFor(seconds: 300)))
        )
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: StubToolsCallHandler.method),
            handlers: [handler]
        )

        let resultValue = try await sink.successResult()
        let result = try XCTUnwrap(resultValue)
        XCTAssertNil(result["ttlMs"])
        XCTAssertNil(result["cacheScope"])
        XCTAssertEqual(result["resultType"]?.stringValue, "complete")
    }

    func testARetriedRequestCarryingInputResponsesIsNotCacheable() async throws {
        let handler = StubResourcesReadHandler(
            behavior: .returning(.complete(["contents": .array([])], cacheHint: .privateFor(seconds: 60)))
        )
        let request = MCPProtocolTestSupport.makeModernRequest(
            method: StubResourcesReadHandler.method,
            payload: ["inputResponses": .array([.object(["value": .string("yes")])])]
        )
        let sink = try await dispatch(request, handlers: [handler])

        let resultValue = try await sink.successResult()
        let result = try XCTUnwrap(resultValue)
        XCTAssertEqual(result["ttlMs"]?.intValue, 0)
        XCTAssertEqual(result["cacheScope"]?.stringValue, "private")
    }

    func testAnInterimResultCarriesNoCacheHint() async throws {
        let interim = MCPResult(kind: .inputRequired, payload: ["inputRequests": .array([])])
        let handler = StubResourcesReadHandler(behavior: .returning(interim))
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: StubResourcesReadHandler.method),
            handlers: [handler]
        )

        let resultValue = try await sink.successResult()
        let result = try XCTUnwrap(resultValue)
        XCTAssertEqual(result["resultType"]?.stringValue, "input_required")
        XCTAssertNil(result["ttlMs"])
        XCTAssertNil(result["cacheScope"])
    }

    func testAMethodThatMayNotAskForInputCannotReturnAnInterimResult() async throws {
        let interim = MCPResult(kind: .inputRequired, payload: [:])
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: StubTestHandler.method),
            handlers: [StubTestHandler(behavior: .returning(interim))]
        )

        let errorValue = try await sink.errorEnvelope()
        let error = try XCTUnwrap(errorValue)
        XCTAssertEqual(error.code, JsonRpcErrorCode.internalError)
    }

    func testAHandlerThatOverrunsItsDeadlineIsTimedOut() async throws {
        let gate = ReleaseGate()
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeModernRequest(method: StubTestHandler.method),
            handlers: [StubTestHandler(behavior: .blockUntilReleased(gate))],
            handlerTimeout: .milliseconds(60),
            disconnectPollInterval: .milliseconds(20)
        )
        await gate.release()

        let errorValue = try await sink.errorEnvelope()
        let error = try XCTUnwrap(errorValue)
        XCTAssertEqual(error.code, JsonRpcErrorCode.requestTimeout)
        XCTAssertEqual(error.code, -33_003)
    }

    func testClosingTheStreamCancelsTheRequest() async throws {
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
        let error = try XCTUnwrap(errorValue)
        XCTAssertEqual(error.code, JsonRpcErrorCode.requestCancelled)
        XCTAssertEqual(error.code, -33_002)
    }

    func testAnUnknownNotificationIsAcknowledgedAndDropped() async throws {
        let sink = try await dispatch(
            MCPProtocolTestSupport.makeNotification(method: "notifications/initialized"),
            handlers: [StubTestHandler()]
        )

        let accepted = await sink.acceptedCount
        let writes = await sink.jsonWrites.count
        XCTAssertEqual(accepted, 1)
        XCTAssertEqual(writes, 0)
    }

    func testAResponseMessageIsIgnoredAndAcknowledged() async throws {
        let response = JsonRpcMessage.successResponse(JsonRpcSuccessResponse(id: .number(1), result: .object([:])))
        let sink = try await dispatch(response, handlers: [StubTestHandler()])

        let accepted = await sink.acceptedCount
        XCTAssertEqual(accepted, 1)
    }

    func testACancellationNotificationCancelsTheMatchingRequest() async throws {
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
        let error = try XCTUnwrap(errorValue)
        XCTAssertEqual(error.code, JsonRpcErrorCode.requestCancelled)

        let accepted = await cancelSink.acceptedCount
        XCTAssertEqual(accepted, 1)
        _ = await run
    }

    func testACancellationFromAnotherPrincipalIsIgnored() async throws {
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
        XCTAssertEqual(stillInflight, 1)

        let writes = await sink.jsonWrites.count
        XCTAssertEqual(writes, 0)

        _ = await dispatcher.cancelAllInflight()
        await sink.waitForCompletion()
        _ = await run
    }

    func testRevokingATokenCancelsItsInFlightRequests() async throws {
        let handler = StubTestHandler(behavior: .waitForCancellation)
        let dispatcher = MCPProtocolTestSupport.makeDispatcher(handlers: [handler])
        let request = MCPProtocolTestSupport.makeModernRequest(id: .number(11), method: StubTestHandler.method)
        let (exchange, sink) = MCPProtocolTestSupport.makeExchange(message: request, principal: alice)

        async let run: Void = dispatcher.dispatch(exchange)
        _ = await waitForInflight(dispatcher, count: 1)

        let tokenId = try XCTUnwrap(alice.tokenId)
        let cancelled = await dispatcher.cancelInflight(matchingTokenId: tokenId)
        XCTAssertEqual(cancelled, 1)

        await sink.waitForCompletion()
        let errorValue = try await sink.errorEnvelope()
        let error = try XCTUnwrap(errorValue)
        XCTAssertEqual(error.code, JsonRpcErrorCode.requestCancelled)
        _ = await run
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

final class MCPCancelledNotificationFuzzTests: XCTestCase {
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

    func testAHostileRequestIdIsRejectedInsteadOfTrapping() throws {
        for raw in Self.hostileRequestIds {
            let params = try MCPProtocolTestSupport.jsonValue(fromJson: "{\"requestId\": \(raw)}")
            XCTAssertNil(
                MCPProtocolDispatcher.cancellationRequestId(in: params),
                "requestId \(raw) should not resolve to an in-flight key"
            )
        }
    }

    func testAUsableRequestIdIsResolved() throws {
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
            XCTAssertEqual(MCPProtocolDispatcher.cancellationRequestId(in: params), expected, "requestId \(raw)")
        }
    }

    func testAMissingOrMalformedParamsObjectIsRejected() throws {
        XCTAssertNil(MCPProtocolDispatcher.cancellationRequestId(in: nil))
        XCTAssertNil(MCPProtocolDispatcher.cancellationRequestId(in: .object([:])))
        XCTAssertNil(MCPProtocolDispatcher.cancellationRequestId(in: .string("nope")))
        XCTAssertNil(MCPProtocolDispatcher.cancellationRequestId(in: .array([.int(1)])))
        XCTAssertNil(MCPProtocolDispatcher.cancellationRequestId(in: .object(["requestId": .null])))
    }

    func testHostileCancellationsAreAcknowledgedAndLeaveTheRequestRunning() async throws {
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
            XCTAssertEqual(acknowledged, 1, "cancellation with requestId \(raw) was not acknowledged")

            let inflight = await dispatcher.inflightCount()
            XCTAssertEqual(inflight, 1, "cancellation with requestId \(raw) disturbed an unrelated request")
        }

        let unmatched = await sendCancellation(
            params: .object(["requestId": .string("some-other-request")]),
            to: dispatcher
        )
        XCTAssertEqual(unmatched, 1)

        let writes = await sink.jsonWrites.count
        XCTAssertEqual(writes, 0)

        let acknowledged = await sendCancellation(
            params: .object(["requestId": .string(Self.longIdentifier), "reason": .string("user stopped")]),
            to: dispatcher
        )
        XCTAssertEqual(acknowledged, 1)

        await sink.waitForCompletion()
        let errorValue = try await sink.errorEnvelope()
        let error = try XCTUnwrap(errorValue)
        XCTAssertEqual(error.code, JsonRpcErrorCode.requestCancelled)

        let remaining = await dispatcher.inflightCount()
        XCTAssertEqual(remaining, 0)
        _ = await run
    }

    func testACancellationWithoutAPrincipalIsDroppedButStillAcknowledged() async throws {
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
        XCTAssertEqual(accepted, 1)
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
