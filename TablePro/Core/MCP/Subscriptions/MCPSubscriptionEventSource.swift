import Combine
import Foundation
import os

@MainActor
public final class MCPSubscriptionEventSource {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Subscriptions")

    private weak var registry: MCPSubscriptionRegistry?
    private var cancellables: Set<AnyCancellable> = []
    private var connectedConnections: Set<UUID> = []
    private var schemaGenerations: [UUID: Int] = [:]
    private var observationGeneration = 0
    private var isObserving = false

    public init(registry: MCPSubscriptionRegistry) {
        self.registry = registry
    }

    public func start() {
        guard !isObserving else { return }
        isObserving = true
        connectedConnections = MCPSubscriptionVisibility.visibleConnectedConnectionIds()
        schemaGenerations = SchemaService.shared.generations

        AppEvents.shared.connectionStatusChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleConnectionStatusChange()
            }
            .store(in: &cancellables)

        armSchemaObservation()
        Self.logger.debug("Subscription event source started")
    }

    public func stop() {
        guard isObserving else { return }
        isObserving = false
        observationGeneration &+= 1
        cancellables.removeAll()
        connectedConnections = []
        schemaGenerations = [:]
        Self.logger.debug("Subscription event source stopped")
    }

    private func handleConnectionStatusChange() {
        guard isObserving else { return }
        let current = MCPSubscriptionVisibility.visibleConnectedConnectionIds()
        guard current != connectedConnections else { return }
        connectedConnections = current
        publish(.resourcesListChanged)
    }

    private func armSchemaObservation() {
        guard isObserving else { return }
        observationGeneration &+= 1
        let generation = observationGeneration
        withObservationTracking {
            _ = SchemaService.shared.generations
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isObserving, generation == self.observationGeneration else { return }
                self.armSchemaObservation()
                self.publishSchemaUpdates()
            }
        }
    }

    private func publishSchemaUpdates() {
        let service = SchemaService.shared
        let current = service.generations
        defer { schemaGenerations = current }
        for (connectionId, generation) in current {
            guard schemaGenerations[connectionId] != generation else { continue }
            guard service.hasLoadedContent(for: connectionId) else { continue }
            guard !service.isRefreshing(connectionId: connectionId) else { continue }
            publish(.resourceUpdated(uri: ResourcesUriRoute.schemaUri(connectionId: connectionId)))
        }
    }

    private func publish(_ event: MCPSubscriptionEvent) {
        guard let registry else { return }
        Task { await registry.publish(event) }
    }
}
