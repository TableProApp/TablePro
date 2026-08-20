import Foundation
import os

public enum MCPSubscriptionEvent: Sendable, Equatable {
    case toolsListChanged
    case promptsListChanged
    case resourcesListChanged
    case resourceUpdated(uri: String)
}

public enum MCPSubscriptionNotification {
    public static let acknowledged = "notifications/subscriptions/acknowledged"
    public static let toolsListChanged = "notifications/tools/list_changed"
    public static let promptsListChanged = "notifications/prompts/list_changed"
    public static let resourcesListChanged = "notifications/resources/list_changed"
    public static let resourceUpdated = "notifications/resources/updated"

    public static func message(
        method: String,
        subscriptionId: MCPSubscriptionId,
        params: [String: JsonValue] = [:]
    ) -> JsonRpcMessage {
        var fields = params
        fields["_meta"] = .object([MCPMetaKeys.subscriptionId: subscriptionId.asJsonValue])
        return .notification(JsonRpcNotification(method: method, params: .object(fields)))
    }

    public static func acknowledgment(
        subscriptionId: MCPSubscriptionId,
        filter: MCPSubscriptionFilter
    ) -> JsonRpcMessage {
        message(
            method: acknowledged,
            subscriptionId: subscriptionId,
            params: ["notifications": filter.asJsonValue]
        )
    }
}

public actor MCPSubscriptionRegistry {
    public typealias ConnectedConnectionsProvider = @Sendable () async -> Set<UUID>

    private struct Entry {
        let filter: MCPSubscriptionFilter
        let responder: MCPResponder
        let principal: MCPPrincipal
        var visibleConnections: Set<UUID>
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Subscriptions")
    private static let livenessSweepInterval: Duration = .seconds(15)

    private let connectedConnections: ConnectedConnectionsProvider
    private var entries: [MCPSubscriptionId: Entry] = [:]
    private var closureWaiters: [MCPSubscriptionId: [CheckedContinuation<Void, Never>]] = [:]
    private var livenessTask: Task<Void, Never>?

    public init(
        connectedConnections: @escaping ConnectedConnectionsProvider = MCPSubscriptionVisibility.connectedConnections
    ) {
        self.connectedConnections = connectedConnections
    }

    public var count: Int {
        entries.count
    }

    @discardableResult
    public func open(
        id: JsonRpcId,
        filter: MCPSubscriptionFilter,
        responder: MCPResponder,
        principal: MCPPrincipal
    ) async -> MCPSubscriptionFilter {
        let honoured = filter.honoured(for: principal)
        guard let key = MCPSubscriptionId(requestId: id) else { return honoured }
        let visible = await visibleConnections(for: principal)
        entries[key] = Entry(
            filter: honoured,
            responder: responder,
            principal: principal,
            visibleConnections: visible
        )
        startLivenessSweep()
        Self.logger.debug("Subscription opened id=\(key.description, privacy: .public)")
        return honoured
    }

    public func close(id: JsonRpcId) async {
        guard let key = MCPSubscriptionId(requestId: id) else { return }
        finish(key)
    }

    public func closeAll() async {
        for key in Array(entries.keys) {
            finish(key)
        }
    }

    public func awaitClosure(id: JsonRpcId) async {
        guard let key = MCPSubscriptionId(requestId: id) else { return }
        await withCheckedContinuation { continuation in
            guard entries[key] != nil else {
                continuation.resume()
                return
            }
            closureWaiters[key, default: []].append(continuation)
        }
    }

    public func publish(_ event: MCPSubscriptionEvent) async {
        guard !entries.isEmpty else { return }
        switch event {
        case .toolsListChanged:
            await deliverListChanged(method: MCPSubscriptionNotification.toolsListChanged) { $0.toolsListChanged }
        case .promptsListChanged:
            await deliverListChanged(method: MCPSubscriptionNotification.promptsListChanged) { $0.promptsListChanged }
        case .resourcesListChanged:
            await deliverResourcesListChanged()
        case .resourceUpdated(let uri):
            await deliverResourceUpdated(uri: uri)
        }
    }

    private func deliverListChanged(
        method: String,
        matches: (MCPSubscriptionFilter) -> Bool
    ) async {
        for (key, entry) in entries.filter({ matches($0.value.filter) }) {
            await emit(key: key, entry: entry, method: method, params: [:])
        }
    }

    private func deliverResourcesListChanged() async {
        let connected = await connectedConnections()
        for (key, entry) in entries.filter({ $0.value.filter.resourcesListChanged }) {
            let visible: Set<UUID> = connected.filter { entry.principal.connectionAccess.allows($0) }
            guard visible != entry.visibleConnections else { continue }
            entries[key]?.visibleConnections = visible
            await emit(
                key: key,
                entry: entry,
                method: MCPSubscriptionNotification.resourcesListChanged,
                params: [:]
            )
        }
    }

    private func deliverResourceUpdated(uri: String) async {
        guard let resource = MCPSubscribableResource(uri: uri) else {
            Self.logger.debug("Dropping update for unsubscribable resource")
            return
        }
        let canonical = resource.uri
        for (key, entry) in entries.filter({ $0.value.filter.includes(resourceUri: canonical) }) {
            guard entry.principal.connectionAccess.allows(resource.connectionId) else { continue }
            await emit(
                key: key,
                entry: entry,
                method: MCPSubscriptionNotification.resourceUpdated,
                params: ["uri": .string(canonical)]
            )
        }
    }

    private func emit(key: MCPSubscriptionId, entry: Entry, method: String, params: [String: JsonValue]) async {
        guard entries[key] != nil else { return }
        let disconnected = await entry.responder.clientDisconnected()
        guard !disconnected else {
            finish(key)
            return
        }
        await entry.responder.emit(
            MCPSubscriptionNotification.message(method: method, subscriptionId: key, params: params)
        )
    }

    private func visibleConnections(for principal: MCPPrincipal) async -> Set<UUID> {
        let connected = await connectedConnections()
        return connected.filter { principal.connectionAccess.allows($0) }
    }

    private func finish(_ key: MCPSubscriptionId) {
        guard entries.removeValue(forKey: key) != nil else { return }
        let waiters = closureWaiters.removeValue(forKey: key) ?? []
        for waiter in waiters {
            waiter.resume()
        }
        if entries.isEmpty {
            stopLivenessSweep()
        }
        Self.logger.debug("Subscription closed id=\(key.description, privacy: .public)")
    }

    private func startLivenessSweep() {
        guard livenessTask == nil else { return }
        livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.livenessSweepInterval)
                guard !Task.isCancelled, let self else { return }
                await self.evictDisconnected()
            }
        }
    }

    private func stopLivenessSweep() {
        livenessTask?.cancel()
        livenessTask = nil
    }

    private func evictDisconnected() async {
        let snapshot = entries
        var disconnected: [MCPSubscriptionId] = []
        for (key, entry) in snapshot {
            if await entry.responder.clientDisconnected() {
                disconnected.append(key)
            }
        }
        for key in disconnected {
            finish(key)
        }
    }
}

public enum MCPSubscriptionVisibility {
    public static let connectedConnections: MCPSubscriptionRegistry.ConnectedConnectionsProvider = {
        await MainActor.run { MCPSubscriptionVisibility.visibleConnectedConnectionIds() }
    }

    @MainActor
    static func visibleConnectedConnectionIds() -> Set<UUID> {
        let defaultPolicy = AppSettingsManager.shared.ai.defaultConnectionPolicy
        let sessions = DatabaseManager.shared.activeSessions
        var visible: Set<UUID> = []
        for connection in ConnectionStorage.shared.loadConnections() {
            guard connection.externalAccess != .blocked else { continue }
            guard (connection.aiPolicy ?? defaultPolicy) != .never else { continue }
            guard sessions[connection.id]?.status.isConnected == true else { continue }
            visible.insert(connection.id)
        }
        return visible
    }
}
