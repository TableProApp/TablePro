import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("MCPSubscriptionFilter")
struct MCPSubscriptionFilterTests {
    @Test("Params without a notifications object are invalid")
    func notificationsIsRequired() {
        #expect(throws: MCPProtocolError.self) {
            _ = try MCPSubscriptionFilter.decode(params: nil)
        }
        #expect(throws: MCPProtocolError.self) {
            _ = try MCPSubscriptionFilter.decode(params: .object([:]))
        }
        #expect(throws: MCPProtocolError.self) {
            _ = try MCPSubscriptionFilter.decode(params: .object(["notifications": .string("all")]))
        }
    }

    @Test("A flag that is not a boolean is invalid")
    func flagsMustBeBooleans() {
        #expect(throws: MCPProtocolError.self) {
            _ = try MCPSubscriptionFilter.decode(params: .object([
                "notifications": .object(["resourcesListChanged": .string("yes")])
            ]))
        }
    }

    @Test("Resource subscriptions must be an array of non-empty strings")
    func resourceSubscriptionsShape() {
        #expect(throws: MCPProtocolError.self) {
            _ = try MCPSubscriptionFilter.decode(params: .object([
                "notifications": .object(["resourceSubscriptions": .string("tablepro://connections")])
            ]))
        }
        #expect(throws: MCPProtocolError.self) {
            _ = try MCPSubscriptionFilter.decode(params: .object([
                "notifications": .object(["resourceSubscriptions": .array([.string("")])])
            ]))
        }
    }

    @Test("An omitted field means no subscription to that type")
    func omittedFieldsAreOff() throws {
        let filter = try MCPSubscriptionFilter.decode(params: .object(["notifications": .object([:])]))
        #expect(!filter.toolsListChanged)
        #expect(!filter.promptsListChanged)
        #expect(!filter.resourcesListChanged)
        #expect(filter.resourceSubscriptions.isEmpty)
        #expect(filter.isEmpty)
    }

    @Test("The honoured filter drops the notification types this server does not raise")
    func honouredFilterDropsUnsupportedTypes() {
        let requested = MCPSubscriptionFilter(
            toolsListChanged: true,
            promptsListChanged: true,
            resourcesListChanged: true
        )
        let honoured = requested.honoured(for: SubscriptionFixtures.principal())

        #expect(!honoured.toolsListChanged)
        #expect(!honoured.promptsListChanged)
        #expect(honoured.resourcesListChanged)
    }

    @Test("A principal without the resources read scope is honoured nothing")
    func honouredFilterNeedsResourcesRead() {
        let requested = MCPSubscriptionFilter(resourcesListChanged: true)
        let honoured = requested.honoured(
            for: MCPProtocolTestSupport.makePrincipal(scopes: [.toolsRead])
        )
        #expect(honoured == .none)
    }

    @Test("A resource for a connection outside the grant is dropped from the honoured filter")
    func honouredFilterRespectsConnectionAccess() {
        let requested = MCPSubscriptionFilter(resourceSubscriptions: [
            ResourcesUriRoute.schemaUri(connectionId: SubscriptionFixtures.granted),
            ResourcesUriRoute.schemaUri(connectionId: SubscriptionFixtures.denied)
        ])
        let honoured = requested.honoured(
            for: SubscriptionFixtures.principal(connectionAccess: .limited([SubscriptionFixtures.granted]))
        )

        #expect(honoured.resourceSubscriptions == [
            ResourcesUriRoute.schemaUri(connectionId: SubscriptionFixtures.granted)
        ])
    }

    @Test("A resource URI is canonicalised so a lowercase identifier still matches")
    func honouredFilterCanonicalisesUris() {
        let lowercased = ResourcesUriRoute.schemaUri(connectionId: SubscriptionFixtures.granted).lowercased()
        let honoured = MCPSubscriptionFilter(resourceSubscriptions: [lowercased])
            .honoured(for: SubscriptionFixtures.principal())

        #expect(honoured.resourceSubscriptions == [
            ResourcesUriRoute.schemaUri(connectionId: SubscriptionFixtures.granted)
        ])
    }

    @Test("A URI that nothing can publish updates for is dropped")
    func honouredFilterDropsUnsubscribableUris() {
        let honoured = MCPSubscriptionFilter(resourceSubscriptions: [
            ResourcesUriRoute.Template.connections,
            "not-even-a-uri"
        ])
        .honoured(for: SubscriptionFixtures.principal())

        #expect(honoured.resourceSubscriptions.isEmpty)
    }

    @Test("A duplicate resource URI is registered once")
    func duplicateUrisCollapse() {
        let uri = ResourcesUriRoute.schemaUri(connectionId: SubscriptionFixtures.granted)
        let filter = MCPSubscriptionFilter(resourceSubscriptions: [uri, uri])
        #expect(filter.resourceSubscriptions == [uri])
    }

    @Test("Serialising a filter omits everything it did not ask for")
    func serialisationOmitsUnsetFields() {
        let json = MCPSubscriptionFilter(resourcesListChanged: true).asJsonValue
        #expect(json["resourcesListChanged"]?.boolValue == true)
        #expect(json["toolsListChanged"] == nil)
        #expect(json["promptsListChanged"] == nil)
        #expect(json["resourceSubscriptions"] == nil)
        #expect(MCPSubscriptionFilter.none.asJsonValue == .object([:]))
    }
}

@Suite("MCPSubscriptionRegistry")
struct MCPSubscriptionRegistryTests {
    @Test("Opening a subscription answers with the subset the server honours")
    func openReturnsHonouredFilter() async {
        let registry = MCPSubscriptionRegistry(connectedConnections: { [] })
        let sink = RecordingResponderSink()
        let honoured = await registry.open(
            id: .number(1),
            filter: MCPSubscriptionFilter(toolsListChanged: true, resourcesListChanged: true),
            responder: MCPResponder(sink: sink, requestId: .number(1)),
            principal: SubscriptionFixtures.principal()
        )

        #expect(!honoured.toolsListChanged)
        #expect(honoured.resourcesListChanged)
        let count = await registry.count
        #expect(count == 1)
        await registry.closeAll()
    }

    @Test("A null request id cannot open a subscription")
    func nullRequestIdIsNotRegistrable() async {
        let registry = MCPSubscriptionRegistry(connectedConnections: { [] })
        let sink = RecordingResponderSink()
        _ = await registry.open(
            id: .null,
            filter: MCPSubscriptionFilter(resourcesListChanged: true),
            responder: MCPResponder(sink: sink, requestId: nil),
            principal: SubscriptionFixtures.principal()
        )

        let count = await registry.count
        #expect(count == 0)
    }

    @Test("A list-changed notification the client never asked for is never sent")
    func unrequestedTypesAreNeverSent() async throws {
        let connections = MutableConnectionSet(SubscriptionFixtures.bothConnections)
        let registry = MCPSubscriptionRegistry(connectedConnections: { await connections.value })
        let sink = RecordingResponderSink()
        await registry.open(
            id: .number(1),
            filter: MCPSubscriptionFilter(resourceSubscriptions: [SubscriptionFixtures.grantedUri]),
            responder: MCPResponder(sink: sink, requestId: .number(1)),
            principal: SubscriptionFixtures.principal()
        )

        await registry.publish(.toolsListChanged)
        await registry.publish(.promptsListChanged)
        await registry.publish(.resourcesListChanged)

        let frames = await sink.sseFrames
        #expect(frames.isEmpty)
        await registry.closeAll()
    }

    @Test("Every notification carries the subscription id of the request that opened the stream")
    func notificationsCarryTheSubscriptionId() async throws {
        let connections = MutableConnectionSet([])
        let registry = MCPSubscriptionRegistry(connectedConnections: { await connections.value })
        let sink = RecordingResponderSink()
        await registry.open(
            id: .string("stream-a"),
            filter: MCPSubscriptionFilter(
                resourcesListChanged: true,
                resourceSubscriptions: [SubscriptionFixtures.grantedUri]
            ),
            responder: MCPResponder(sink: sink, requestId: .string("stream-a")),
            principal: SubscriptionFixtures.principal()
        )

        await connections.set(SubscriptionFixtures.bothConnections)
        await registry.publish(.resourcesListChanged)
        await registry.publish(.resourceUpdated(uri: SubscriptionFixtures.grantedUri))

        let messages = try await sink.sseMessages()
        #expect(messages.count == 2)
        for message in messages {
            guard case .notification(let notification) = message else {
                Issue.record("Expected a notification, got \(message)")
                continue
            }
            let subscriptionId = notification.params?["_meta"]?[MCPMetaKeys.subscriptionId]
            #expect(subscriptionId == .string("stream-a"))
        }
        await registry.closeAll()
    }

    @Test("A resource update reaches only the streams that subscribed to that URI")
    func resourceUpdatesAreRouted() async throws {
        let registry = MCPSubscriptionRegistry(connectedConnections: { SubscriptionFixtures.bothConnections })
        let subscribed = RecordingResponderSink()
        let unsubscribed = RecordingResponderSink()

        await registry.open(
            id: .number(1),
            filter: MCPSubscriptionFilter(resourceSubscriptions: [SubscriptionFixtures.grantedUri]),
            responder: MCPResponder(sink: subscribed, requestId: .number(1)),
            principal: SubscriptionFixtures.principal()
        )
        await registry.open(
            id: .number(2),
            filter: MCPSubscriptionFilter(resourceSubscriptions: [SubscriptionFixtures.deniedUri]),
            responder: MCPResponder(sink: unsubscribed, requestId: .number(2)),
            principal: SubscriptionFixtures.principal()
        )

        await registry.publish(.resourceUpdated(uri: SubscriptionFixtures.grantedUri))

        let delivered = try await subscribed.sseMessages()
        #expect(delivered.count == 1)
        if case .notification(let notification) = delivered[0] {
            #expect(notification.method == MCPSubscriptionNotification.resourceUpdated)
            #expect(notification.params?["uri"]?.stringValue == SubscriptionFixtures.grantedUri)
        } else {
            Issue.record("Expected a notification")
        }

        let others = await unsubscribed.sseFrames
        #expect(others.isEmpty)
        await registry.closeAll()
    }

    @Test("A principal restricted to a subset is never told about a connection outside its grant")
    func restrictedPrincipalNeverHearsAboutForeignConnections() async {
        let registry = MCPSubscriptionRegistry(connectedConnections: { SubscriptionFixtures.bothConnections })
        let sink = RecordingResponderSink()

        let honoured = await registry.open(
            id: .number(1),
            filter: MCPSubscriptionFilter(resourceSubscriptions: [
                SubscriptionFixtures.grantedUri,
                SubscriptionFixtures.deniedUri
            ]),
            responder: MCPResponder(sink: sink, requestId: .number(1)),
            principal: SubscriptionFixtures.principal(
                connectionAccess: .limited([SubscriptionFixtures.granted])
            )
        )
        #expect(honoured.resourceSubscriptions == [SubscriptionFixtures.grantedUri])

        await registry.publish(.resourceUpdated(uri: SubscriptionFixtures.deniedUri))

        let frames = await sink.sseFrames
        #expect(frames.isEmpty)
        await registry.closeAll()
    }

    @Test("A resources list change only fires when the visible connection set actually changed")
    func resourcesListChangedIsDeduplicated() async {
        let connections = MutableConnectionSet([SubscriptionFixtures.granted])
        let registry = MCPSubscriptionRegistry(connectedConnections: { await connections.value })
        let sink = RecordingResponderSink()

        await registry.open(
            id: .number(1),
            filter: MCPSubscriptionFilter(resourcesListChanged: true),
            responder: MCPResponder(sink: sink, requestId: .number(1)),
            principal: SubscriptionFixtures.principal()
        )

        await registry.publish(.resourcesListChanged)
        let unchanged = await sink.sseFrames
        #expect(unchanged.isEmpty)

        await connections.set(SubscriptionFixtures.bothConnections)
        await registry.publish(.resourcesListChanged)
        let changed = await sink.sseFrames
        #expect(changed.count == 1)
        await registry.closeAll()
    }

    @Test("A resources list change a restricted principal cannot see does not wake its stream")
    func resourcesListChangeOutsideTheGrantIsSilent() async {
        let connections = MutableConnectionSet([SubscriptionFixtures.granted])
        let registry = MCPSubscriptionRegistry(connectedConnections: { await connections.value })
        let sink = RecordingResponderSink()

        await registry.open(
            id: .number(1),
            filter: MCPSubscriptionFilter(resourcesListChanged: true),
            responder: MCPResponder(sink: sink, requestId: .number(1)),
            principal: SubscriptionFixtures.principal(
                connectionAccess: .limited([SubscriptionFixtures.granted])
            )
        )

        await connections.set(SubscriptionFixtures.bothConnections)
        await registry.publish(.resourcesListChanged)

        let frames = await sink.sseFrames
        #expect(frames.isEmpty)
        await registry.closeAll()
    }

    @Test("A dropped connection removes the registry entry")
    func droppedConnectionEvictsTheEntry() async {
        let registry = MCPSubscriptionRegistry(connectedConnections: { SubscriptionFixtures.bothConnections })
        let sink = RecordingResponderSink()

        await registry.open(
            id: .number(1),
            filter: MCPSubscriptionFilter(resourceSubscriptions: [SubscriptionFixtures.grantedUri]),
            responder: MCPResponder(sink: sink, requestId: .number(1)),
            principal: SubscriptionFixtures.principal()
        )
        await sink.disconnectClient()
        await registry.publish(.resourceUpdated(uri: SubscriptionFixtures.grantedUri))

        let count = await registry.count
        #expect(count == 0)
        let frames = await sink.sseFrames
        #expect(frames.isEmpty)
    }

    @Test("Closing a subscription resumes whoever is waiting on it")
    func closeResumesWaiters() async {
        let registry = MCPSubscriptionRegistry(connectedConnections: { [] })
        let sink = RecordingResponderSink()
        await registry.open(
            id: .number(7),
            filter: MCPSubscriptionFilter(resourcesListChanged: true),
            responder: MCPResponder(sink: sink, requestId: .number(7)),
            principal: SubscriptionFixtures.principal()
        )

        let waiter = Task { await registry.awaitClosure(id: .number(7)) }
        await registry.close(id: .number(7))
        await waiter.value

        let count = await registry.count
        #expect(count == 0)
    }

    @Test("Waiting on a subscription that was never opened returns at once")
    func awaitingAnUnknownSubscriptionReturns() async {
        let registry = MCPSubscriptionRegistry(connectedConnections: { [] })
        await registry.awaitClosure(id: .number(99))
        let count = await registry.count
        #expect(count == 0)
    }

    @Test("Closing everything resumes every waiter")
    func closeAllResumesEveryWaiter() async {
        let registry = MCPSubscriptionRegistry(connectedConnections: { [] })
        let identifiers: [JsonRpcId] = [.number(1), .number(2), .number(3)]
        for identifier in identifiers {
            let sink = RecordingResponderSink()
            await registry.open(
                id: identifier,
                filter: MCPSubscriptionFilter(resourcesListChanged: true),
                responder: MCPResponder(sink: sink, requestId: identifier),
                principal: SubscriptionFixtures.principal()
            )
        }

        let waiters = identifiers.map { identifier in
            Task { await registry.awaitClosure(id: identifier) }
        }
        await registry.closeAll()
        for waiter in waiters {
            await waiter.value
        }

        let count = await registry.count
        #expect(count == 0)
    }
}

@Suite("MCPSubscriptionNotification")
struct MCPSubscriptionNotificationTests {
    @Test("Every notification method is namespaced under notifications/")
    func methodNames() {
        #expect(MCPSubscriptionNotification.acknowledged == "notifications/subscriptions/acknowledged")
        #expect(MCPSubscriptionNotification.toolsListChanged == "notifications/tools/list_changed")
        #expect(MCPSubscriptionNotification.promptsListChanged == "notifications/prompts/list_changed")
        #expect(MCPSubscriptionNotification.resourcesListChanged == "notifications/resources/list_changed")
        #expect(MCPSubscriptionNotification.resourceUpdated == "notifications/resources/updated")
    }

    @Test("The acknowledgment carries the subscription id and the honoured filter")
    func acknowledgmentShape() throws {
        let subscriptionId = try #require(MCPSubscriptionId(requestId: .number(4)))
        let message = MCPSubscriptionNotification.acknowledgment(
            subscriptionId: subscriptionId,
            filter: MCPSubscriptionFilter(resourcesListChanged: true)
        )

        guard case .notification(let notification) = message else {
            Issue.record("Expected a notification")
            return
        }
        #expect(notification.method == MCPSubscriptionNotification.acknowledged)
        #expect(notification.params?["_meta"]?[MCPMetaKeys.subscriptionId] == .int(4))
        #expect(notification.params?["notifications"]?["resourcesListChanged"]?.boolValue == true)
    }

    @Test("A string request id becomes a string subscription id and a null one is not an id at all")
    func subscriptionIdMapping() throws {
        #expect(MCPSubscriptionId(requestId: .null) == nil)
        let text = try #require(MCPSubscriptionId(requestId: .string("abc")))
        #expect(text.asJsonValue == .string("abc"))
        #expect(text.description == "abc")
        let number = try #require(MCPSubscriptionId(requestId: .number(12)))
        #expect(number.asJsonValue == .int(12))
    }
}

enum SubscriptionFixtures {
    static let granted = UUID(uuidString: "0D000000-0000-4000-8000-000000000001") ?? UUID()
    static let denied = UUID(uuidString: "0E000000-0000-4000-8000-000000000002") ?? UUID()

    static let bothConnections: Set<UUID> = [granted, denied]

    static var grantedUri: String {
        ResourcesUriRoute.schemaUri(connectionId: granted)
    }

    static var deniedUri: String {
        ResourcesUriRoute.schemaUri(connectionId: denied)
    }

    static func principal(connectionAccess: ConnectionAccess = .all) -> MCPPrincipal {
        MCPProtocolTestSupport.makePrincipal(
            scopes: MCPScope.readOnlySet,
            connectionAccess: connectionAccess
        )
    }
}

actor MutableConnectionSet {
    private(set) var value: Set<UUID>

    init(_ value: Set<UUID>) {
        self.value = value
    }

    func set(_ newValue: Set<UUID>) {
        value = newValue
    }
}
