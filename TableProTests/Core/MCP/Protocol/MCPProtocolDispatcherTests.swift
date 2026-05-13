import Foundation
import TableProPluginKit
@testable import TablePro
import XCTest

final class MCPProtocolDispatcherTests: XCTestCase {
    func testMethodNotFoundReturnsErrorResponse() async throws {
        let store = MCPSessionStore()
        let session = try await store.create()
        let sessionId = await session.id
        let dispatcher = MCPProtocolDispatcher(
            handlers: [InitializeHandler(), PingHandler()],
            sessionStore: store,
            progressSink: StubProgressSink()
        )

        let request = MCPProtocolTestSupport.makeRequest(
            id: .number(1),
            method: "unknown/method"
        )
        let (exchange, sink) = MCPProtocolTestSupport.makeExchange(
            message: request,
            sessionId: sessionId
        )

        await dispatcher.dispatch(exchange)
        await sink.waitForCompletion()

        let decoded = try await sink.firstJsonMessage()
        guard case .errorResponse(let envelope) = decoded else {
            XCTFail("Expected error response, got \(String(describing: decoded))")
            return
        }
        XCTAssertEqual(envelope.error.code, JsonRpcErrorCode.methodNotFound)
        XCTAssertEqual(envelope.id, .number(1))
    }

    func testUninitializedSessionRejectsNonInitializeMethods() async throws {
        let store = MCPSessionStore()
        let session = try await store.create()
        let sessionId = await session.id
        let dispatcher = MCPProtocolDispatcher(
            handlers: [InitializeHandler(), StubToolsListHandler()],
            sessionStore: store,
            progressSink: StubProgressSink()
        )

        let request = MCPProtocolTestSupport.makeRequest(
            id: .number(2),
            method: "tools/list"
        )
        let (exchange, sink) = MCPProtocolTestSupport.makeExchange(
            message: request,
            sessionId: sessionId
        )

        await dispatcher.dispatch(exchange)
        await sink.waitForCompletion()

        let decoded = try await sink.firstJsonMessage()
        guard case .errorResponse(let envelope) = decoded else {
            XCTFail("Expected error response, got \(String(describing: decoded))")
            return
        }
        XCTAssertEqual(envelope.error.code, JsonRpcErrorCode.invalidRequest)
    }

    func testInitializeCreatesSessionAndNotificationTransitionsToReady() async throws {
        let store = MCPSessionStore()
        let dispatcher = MCPProtocolDispatcher(
            handlers: [InitializeHandler()],
            sessionStore: store,
            progressSink: StubProgressSink()
        )

        let eventStream = await store.events
        let collectorTask = Task<MCPSessionId?, Never> {
            for await event in eventStream {
                if case .created(let id) = event {
                    return id
                }
            }
            return nil
        }

        let initRequest = MCPProtocolTestSupport.makeRequest(
            id: .number(10),
            method: "initialize",
            params: .object([
                "protocolVersion": .string("2025-03-26"),
                "clientInfo": .object(["name": .string("client-x")]),
                "capabilities": .object([:])
            ])
        )
        let (initExchange, initSink) = MCPProtocolTestSupport.makeExchange(message: initRequest)

        await dispatcher.dispatch(initExchange)
        await initSink.waitForCompletion()

        let initResponse = try await initSink.firstJsonMessage()
        guard case .successResponse = initResponse else {
            XCTFail("Expected success response, got \(String(describing: initResponse))")
            return
        }

        let sessionCount = await store.count()
        XCTAssertEqual(sessionCount, 1)

        guard let createdId = await collectorTask.value else {
            XCTFail("Expected the dispatcher to have created a session")
            return
        }
        guard let session = await store.session(id: createdId) else {
            XCTFail("Expected to find created session in store")
            return
        }
        let sessionId = await session.id

        let stateAfterInitialize = await session.state
        XCTAssertEqual(stateAfterInitialize, .initializing)

        let initializedNotification = MCPProtocolTestSupport.makeNotification(
            method: "notifications/initialized"
        )
        let (notifExchange, notifSink) = MCPProtocolTestSupport.makeExchange(
            message: initializedNotification,
            sessionId: sessionId
        )

        await dispatcher.dispatch(notifExchange)
        await notifSink.waitForCompletion()

        let stateAfterNotification = await session.state
        XCTAssertEqual(stateAfterNotification, .ready)

        let acceptedCount = await notifSink.acceptedCount
        XCTAssertEqual(acceptedCount, 1)
    }

    func testAuthScopeCheckRejectsInsufficientScopes() async throws {
        let store = MCPSessionStore()
        let session = try await store.create()
        let sessionId = await session.id
        try await session.transitionToReady()

        let dispatcher = MCPProtocolDispatcher(
            handlers: [ScopedToolsCallHandler()],
            sessionStore: store,
            progressSink: StubProgressSink()
        )

        let principal = MCPProtocolTestSupport.makePrincipal(scopes: [.toolsRead])
        let request = MCPProtocolTestSupport.makeRequest(
            id: .number(3),
            method: "tools/call"
        )
        let (exchange, sink) = MCPProtocolTestSupport.makeExchange(
            message: request,
            sessionId: sessionId,
            principal: principal
        )

        await dispatcher.dispatch(exchange)
        await sink.waitForCompletion()

        let decoded = try await sink.firstJsonMessage()
        guard case .errorResponse(let envelope) = decoded else {
            XCTFail("Expected error response, got \(String(describing: decoded))")
            return
        }
        XCTAssertEqual(envelope.error.code, JsonRpcErrorCode.forbidden)
    }

    func testCancellationFlowDeliversCancelledError() async throws {
        let store = MCPSessionStore()
        let session = try await store.create()
        let sessionId = await session.id
        try await session.transitionToReady()

        let stubHandler = StubMethodHandler(behavior: .waitForCancellation)
        let dispatcher = MCPProtocolDispatcher(
            handlers: [stubHandler],
            sessionStore: store,
            progressSink: StubProgressSink()
        )
        let stubMethod = StubMethodHandler.method

        let requestId = JsonRpcId.number(7)
        let request = MCPProtocolTestSupport.makeRequest(id: requestId, method: stubMethod)
        let (exchange, sink) = MCPProtocolTestSupport.makeExchange(
            message: request,
            sessionId: sessionId
        )

        let dispatchTask = Task {
            await dispatcher.dispatch(exchange)
        }

        try await waitUntil(timeoutMs: 2_000) {
            await stubHandler.started.value()
        }

        let cancelNotification = MCPProtocolTestSupport.makeNotification(
            method: "notifications/cancelled",
            params: .object(["requestId": .int(7)])
        )
        let (cancelExchange, cancelSink) = MCPProtocolTestSupport.makeExchange(
            message: cancelNotification,
            sessionId: sessionId
        )

        await dispatcher.dispatch(cancelExchange)
        await cancelSink.waitForCompletion()

        await dispatchTask.value
        await sink.waitForCompletion()

        let decoded = try await sink.firstJsonMessage()
        guard case .errorResponse(let envelope) = decoded else {
            XCTFail("Expected error response, got \(String(describing: decoded))")
            return
        }
        XCTAssertEqual(envelope.error.code, JsonRpcErrorCode.requestCancelled)

        let observed = await stubHandler.observedCancel.value()
        XCTAssertTrue(observed)
    }

    func testInboundResponsesAreIgnored() async throws {
        let store = MCPSessionStore()
        let dispatcher = MCPProtocolDispatcher(
            handlers: [PingHandler()],
            sessionStore: store,
            progressSink: StubProgressSink()
        )

        let response = JsonRpcMessage.successResponse(
            JsonRpcSuccessResponse(id: .number(99), result: .object([:]))
        )
        let (exchange, sink) = MCPProtocolTestSupport.makeExchange(message: response)

        await dispatcher.dispatch(exchange)
        await sink.waitForCompletion()

        let acceptedCount = await sink.acceptedCount
        XCTAssertEqual(acceptedCount, 1)
        let jsonWrites = await sink.jsonWrites
        XCTAssertTrue(jsonWrites.isEmpty)
    }

    func testNotificationInitializedTransitionsSessionWithoutResponse() async throws {
        let store = MCPSessionStore()
        let session = try await store.create()
        let sessionId = await session.id
        let dispatcher = MCPProtocolDispatcher(
            handlers: [],
            sessionStore: store,
            progressSink: StubProgressSink()
        )

        let stateBefore = await session.state
        XCTAssertEqual(stateBefore, .initializing)

        let notification = MCPProtocolTestSupport.makeNotification(
            method: "notifications/initialized"
        )
        let (exchange, sink) = MCPProtocolTestSupport.makeExchange(
            message: notification,
            sessionId: sessionId
        )

        await dispatcher.dispatch(exchange)
        await sink.waitForCompletion()

        let stateAfter = await session.state
        XCTAssertEqual(stateAfter, .ready)

        let acceptedCount = await sink.acceptedCount
        XCTAssertEqual(acceptedCount, 1)
        let writes = await sink.jsonWrites
        XCTAssertTrue(writes.isEmpty)
    }

    func testConcurrentRequestsInSameSessionAllComplete() async throws {
        let store = MCPSessionStore()
        let session = try await store.create()
        let sessionId = await session.id
        try await session.transitionToReady()

        let dispatcher = MCPProtocolDispatcher(
            handlers: [PingHandler()],
            sessionStore: store,
            progressSink: StubProgressSink()
        )

        let count = 5
        var sinks: [RecordingResponderSink] = []
        sinks.reserveCapacity(count)

        await withTaskGroup(of: RecordingResponderSink.self) { group in
            for index in 0..<count {
                let request = MCPProtocolTestSupport.makeRequest(
                    id: .number(Int64(index + 1)),
                    method: "ping"
                )
                let (exchange, sink) = MCPProtocolTestSupport.makeExchange(
                    message: request,
                    sessionId: sessionId
                )
                group.addTask {
                    await dispatcher.dispatch(exchange)
                    await sink.waitForCompletion()
                    return sink
                }
            }
            for await sink in group {
                sinks.append(sink)
            }
        }

        XCTAssertEqual(sinks.count, count)

        var seenIds = Set<Int64>()
        for sink in sinks {
            let decoded = try await sink.firstJsonMessage()
            guard case .successResponse(let success) = decoded else {
                XCTFail("Expected success response, got \(String(describing: decoded))")
                return
            }
            guard case .number(let value) = success.id else {
                XCTFail("Expected numeric id, got \(success.id)")
                return
            }
            seenIds.insert(value)
        }
        XCTAssertEqual(seenIds, Set((1...count).map { Int64($0) }))
    }

    func testHandlerThrowingProtocolErrorYieldsErrorResponse() async throws {
        let store = MCPSessionStore()
        let session = try await store.create()
        let sessionId = await session.id
        try await session.transitionToReady()

        let stubError = MCPProtocolError.invalidParams(detail: "bad shape")
        let handler = StubMethodHandler(behavior: .throwProtocolError(stubError))
        let dispatcher = MCPProtocolDispatcher(
            handlers: [handler],
            sessionStore: store,
            progressSink: StubProgressSink()
        )

        let request = MCPProtocolTestSupport.makeRequest(
            id: .number(11),
            method: StubMethodHandler.method
        )
        let (exchange, sink) = MCPProtocolTestSupport.makeExchange(
            message: request,
            sessionId: sessionId
        )

        await dispatcher.dispatch(exchange)
        await sink.waitForCompletion()

        let decoded = try await sink.firstJsonMessage()
        guard case .errorResponse(let envelope) = decoded else {
            XCTFail("Expected error response, got \(String(describing: decoded))")
            return
        }
        XCTAssertEqual(envelope.error.code, JsonRpcErrorCode.invalidParams)
    }

    func testRequestWithoutSessionIdAndNonInitializeMethodFails() async throws {
        let store = MCPSessionStore()
        let dispatcher = MCPProtocolDispatcher(
            handlers: [PingHandler()],
            sessionStore: store,
            progressSink: StubProgressSink()
        )

        let request = MCPProtocolTestSupport.makeRequest(
            id: .number(20),
            method: "ping"
        )
        let (exchange, sink) = MCPProtocolTestSupport.makeExchange(
            message: request,
            sessionId: nil
        )

        await dispatcher.dispatch(exchange)
        await sink.waitForCompletion()

        let decoded = try await sink.firstJsonMessage()
        guard case .errorResponse(let envelope) = decoded else {
            XCTFail("Expected error response, got \(String(describing: decoded))")
            return
        }
        XCTAssertEqual(envelope.error.code, JsonRpcErrorCode.sessionNotFound)
    }

    private func waitUntil(
        timeoutMs: UInt64,
        _ predicate: @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1_000.0)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if await predicate() { return }
        XCTFail("Timed out waiting for condition after \(timeoutMs)ms")
    }
}
