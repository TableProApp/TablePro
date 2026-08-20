import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("SubscriptionsListenHandler")
struct MCPSubscriptionsListenTests {
    @Test("Handler declares subscriptions/listen and is modern only")
    func metadata() {
        #expect(SubscriptionsListenHandler.method == "subscriptions/listen")
        #expect(SubscriptionsListenHandler.requiredScopes.isEmpty)
        #expect(!SubscriptionsListenHandler.isAvailableToLegacyClients)
    }

    @Test("A subscription needs an id to correlate its notifications with")
    func nullRequestIdIsRefused() async throws {
        let registry = MCPSubscriptionRegistry(connectedConnections: { [] })
        let handler = SubscriptionsListenHandler(subscriptions: registry)
        let context = await MCPProtocolHandlerTestSupport.makeContext(
            method: SubscriptionsListenHandler.method,
            principalScopes: MCPScope.readOnlySet,
            requestId: .null
        )

        await #expect(throws: MCPProtocolError.self) {
            _ = try await handler.handle(
                params: .object(["notifications": .object(["resourcesListChanged": .bool(true)])]),
                context: context
            )
        }
    }

    @Test("Params without a notifications filter are invalid")
    func missingFilterIsRefused() async throws {
        let registry = MCPSubscriptionRegistry(connectedConnections: { [] })
        let handler = SubscriptionsListenHandler(subscriptions: registry)
        let context = await MCPProtocolHandlerTestSupport.makeContext(
            method: SubscriptionsListenHandler.method,
            principalScopes: MCPScope.readOnlySet
        )

        await #expect(throws: MCPProtocolError.self) {
            _ = try await handler.handle(params: .object([:]), context: context)
        }
    }

    @Test("The acknowledgment is the first message on the stream and carries the subscription id")
    func acknowledgmentComesFirst() async throws {
        let session = try await ListenSession.start(
            requestId: .number(1),
            notifications: .object([
                "resourcesListChanged": .bool(true),
                "resourceSubscriptions": .array([.string(SubscriptionFixtures.grantedUri)])
            ])
        )

        let first = try await session.message(at: 0)
        guard case .notification(let acknowledgment) = first else {
            Issue.record("Expected the acknowledgment notification, got \(first)")
            _ = try? await session.finish()
            return
        }
        #expect(acknowledgment.method == MCPSubscriptionNotification.acknowledged)
        #expect(acknowledgment.params?["_meta"]?[MCPMetaKeys.subscriptionId] == .int(1))

        _ = try await session.finish()
    }

    @Test("The acknowledged filter names only the types this server honours")
    func acknowledgedFilterReflectsWhatIsHonoured() async throws {
        let session = try await ListenSession.start(
            requestId: .number(1),
            notifications: .object([
                "toolsListChanged": .bool(true),
                "promptsListChanged": .bool(true),
                "resourcesListChanged": .bool(true),
                "resourceSubscriptions": .array([.string(SubscriptionFixtures.grantedUri)])
            ])
        )

        let first = try await session.message(at: 0)
        guard case .notification(let acknowledgment) = first else {
            Issue.record("Expected the acknowledgment notification")
            _ = try? await session.finish()
            return
        }
        let honoured = try #require(acknowledgment.params?["notifications"])
        #expect(honoured["toolsListChanged"] == nil)
        #expect(honoured["promptsListChanged"] == nil)
        #expect(honoured["resourcesListChanged"]?.boolValue == true)
        #expect(
            honoured["resourceSubscriptions"]?.arrayValue?.compactMap(\.stringValue)
                == [SubscriptionFixtures.grantedUri]
        )

        _ = try await session.finish()
    }

    @Test("Every later notification carries the same subscription id")
    func laterNotificationsCarryTheSubscriptionId() async throws {
        let session = try await ListenSession.start(
            requestId: .string("stream-7"),
            notifications: .object([
                "resourceSubscriptions": .array([.string(SubscriptionFixtures.grantedUri)])
            ])
        )

        await session.registry.publish(.resourceUpdated(uri: SubscriptionFixtures.grantedUri))
        let update = try await session.message(at: 1)
        guard case .notification(let notification) = update else {
            Issue.record("Expected a resource update notification")
            _ = try? await session.finish()
            return
        }
        #expect(notification.method == MCPSubscriptionNotification.resourceUpdated)
        #expect(notification.params?["_meta"]?[MCPMetaKeys.subscriptionId] == .string("stream-7"))
        #expect(notification.params?["uri"]?.stringValue == SubscriptionFixtures.grantedUri)

        _ = try await session.finish()
    }

    @Test("A notification type the client did not request never reaches the stream")
    func unrequestedTypesNeverReachTheStream() async throws {
        let session = try await ListenSession.start(
            requestId: .number(1),
            notifications: .object([
                "resourceSubscriptions": .array([.string(SubscriptionFixtures.grantedUri)])
            ])
        )

        await session.registry.publish(.toolsListChanged)
        await session.registry.publish(.promptsListChanged)
        await session.registry.publish(.resourcesListChanged)

        let messages = try await session.messages()
        #expect(messages.count == 1)

        _ = try await session.finish()
    }

    @Test("A principal restricted to a subset is never told about a connection outside its grant")
    func restrictedPrincipalHearsNothingForeign() async throws {
        let session = try await ListenSession.start(
            requestId: .number(1),
            notifications: .object([
                "resourceSubscriptions": .array([
                    .string(SubscriptionFixtures.grantedUri),
                    .string(SubscriptionFixtures.deniedUri)
                ])
            ]),
            principal: SubscriptionFixtures.principal(
                connectionAccess: .limited([SubscriptionFixtures.granted])
            )
        )

        let acknowledgment = try await session.message(at: 0)
        guard case .notification(let ack) = acknowledgment else {
            Issue.record("Expected the acknowledgment notification")
            _ = try? await session.finish()
            return
        }
        let uris = ack.params?["notifications"]?["resourceSubscriptions"]?.arrayValue?
            .compactMap(\.stringValue) ?? []
        #expect(uris == [SubscriptionFixtures.grantedUri])

        await session.registry.publish(.resourceUpdated(uri: SubscriptionFixtures.deniedUri))
        let messages = try await session.messages()
        #expect(messages.count == 1)

        _ = try await session.finish()
    }

    @Test("Graceful closure answers the listen request with the empty result carrying the subscription id")
    func gracefulClosureCarriesTheSubscriptionId() async throws {
        let session = try await ListenSession.start(
            requestId: .number(4),
            notifications: .object(["resourcesListChanged": .bool(true)])
        )

        let result = try await session.finish()
        #expect(result.kind == .complete)
        #expect(result.payload.isEmpty)
        #expect(result.cacheHint == nil)
        #expect(result.meta.subscriptionId == .number(4))

        let json = result.asJsonValue(era: .modern, serverInfo: nil)
        #expect(json["resultType"]?.stringValue == "complete")
        #expect(json["_meta"]?[MCPMetaKeys.subscriptionId] == .int(4))
    }

    @Test("A dropped connection removes the registry entry and ends the request")
    func droppedConnectionEndsTheSubscription() async throws {
        let session = try await ListenSession.start(
            requestId: .number(1),
            notifications: .object([
                "resourceSubscriptions": .array([.string(SubscriptionFixtures.grantedUri)])
            ])
        )

        await session.sink.disconnectClient()
        await session.registry.publish(.resourceUpdated(uri: SubscriptionFixtures.grantedUri))

        let result = try await session.value()
        #expect(result.meta.subscriptionId == .number(1))
        let count = await session.registry.count
        #expect(count == 0)
    }

    @Test("Cancelling the request closes the subscription")
    func cancellationClosesTheSubscription() async throws {
        let session = try await ListenSession.start(
            requestId: .number(1),
            notifications: .object(["resourcesListChanged": .bool(true)])
        )

        await session.context.cancellation.cancel(reason: .clientDisconnected)
        _ = try await session.value()

        let count = await session.registry.count
        #expect(count == 0)
    }
}

struct ListenSession: Sendable {
    let registry: MCPSubscriptionRegistry
    let sink: RecordingResponderSink
    let context: MCPRequestContext
    let task: Task<MCPResult, Error>

    static func start(
        requestId: JsonRpcId,
        notifications: JsonValue,
        principal: MCPPrincipal = SubscriptionFixtures.principal(),
        connectedConnections: Set<UUID> = SubscriptionFixtures.bothConnections
    ) async throws -> ListenSession {
        let registry = MCPSubscriptionRegistry(connectedConnections: { connectedConnections })
        let handler = SubscriptionsListenHandler(subscriptions: registry)
        let params = JsonValue.object(["notifications": notifications])
        let (context, sink) = await MCPProtocolHandlerTestSupport.makeContextAndSink(
            method: SubscriptionsListenHandler.method,
            params: params,
            principal: principal,
            requestId: requestId
        )

        let task = Task { try await handler.handle(params: params, context: context) }
        let session = ListenSession(registry: registry, sink: sink, context: context, task: task)
        try await session.poll { await registry.count == 1 }
        return session
    }

    func messages() async throws -> [JsonRpcMessage] {
        try await sink.sseMessages()
    }

    func message(at index: Int) async throws -> JsonRpcMessage {
        let sink = self.sink
        try await poll { await sink.sseFrames.count > index }
        return try await sink.sseMessages()[index]
    }

    func finish() async throws -> MCPResult {
        await registry.close(id: context.requestId)
        return try await task.value
    }

    func value() async throws -> MCPResult {
        try await task.value
    }

    private func poll(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0 ..< 400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ListenSessionError.timedOut
    }
}

enum ListenSessionError: Error {
    case timedOut
}
