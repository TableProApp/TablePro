//
//  SchemaRegistryCache.swift
//  TablePro
//

import Foundation
import os

// Schemas fetched from a connection's Schema Registry, by connection and schema ID, for the session. A registry
// never changes the schema behind an ID, so a fetched one is kept; a failure is kept briefly, so a grid of values
// naming the same ID asks once and a registry that comes back is asked again.
//
// The grid reads synchronously: a miss starts the fetch and the grid redraws on `didLoadSchema`. The viewer awaits it.
internal final class SchemaRegistryCache: Sendable {
    typealias EndpointProvider = @Sendable (UUID) async -> SchemaRegistryEndpoint?

    static let shared = SchemaRegistryCache()

    static let didLoadSchema = Notification.Name("com.TablePro.schemaRegistryCache.didLoadSchema")
    static let connectionIDKey = "connectionID"

    static let failureLifetime: Duration = .seconds(30)

    private struct Key: Hashable {
        let connectionID: UUID
        let schemaID: UInt32
    }

    private enum Entry {
        case loaded(RegistrySchema)
        case failed(SchemaRegistryError, at: ContinuousClock.Instant)
    }

    private struct State {
        var entries: [Key: Entry] = [:]
        var inFlight: [Key: Task<Result<RegistrySchema, SchemaRegistryError>, Never>] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let endpoint: EndpointProvider
    private let transport: SchemaRegistryClient.Transport

    init(
        endpoint: @escaping EndpointProvider = SchemaRegistryCache.savedEndpoint,
        transport: @escaping SchemaRegistryClient.Transport = SchemaRegistryClient.urlSessionTransport
    ) {
        self.endpoint = endpoint
        self.transport = transport
    }

    // The fields a connect resolves, secure ones and a linked credential profile's included.
    static let savedEndpoint: EndpointProvider = { connectionID in
        await MainActor.run {
            guard let connection = ConnectionStorage.shared.loadConnections().first(where: { $0.id == connectionID }) else {
                return nil
            }
            let fields = DatabaseDriverFactory.resolvedAdditionalFields(for: connection) ?? connection.additionalFields
            return SchemaRegistryEndpoint(fields: fields)
        }
    }

    // nil while the schema is being fetched, which a miss starts.
    func cachedSchema(connectionID: UUID, schemaID: UInt32) -> Result<RegistrySchema, SchemaRegistryError>? {
        let key = Key(connectionID: connectionID, schemaID: schemaID)
        if let result = state.withLock({ current(key, in: &$0) }) { return result }
        _ = start(key)
        return nil
    }

    func schema(connectionID: UUID, schemaID: UInt32) async -> Result<RegistrySchema, SchemaRegistryError> {
        let key = Key(connectionID: connectionID, schemaID: schemaID)
        if let result = state.withLock({ current(key, in: &$0) }) { return result }
        return await start(key).value
    }

    // What the grid can use now; an expired failure is dropped so the next read fetches again.
    private func current(_ key: Key, in state: inout State) -> Result<RegistrySchema, SchemaRegistryError>? {
        switch state.entries[key] {
        case .loaded(let schema)?:
            return .success(schema)
        case .failed(let error, let at)?:
            guard ContinuousClock.now - at >= Self.failureLifetime else { return .failure(error) }
            state.entries[key] = nil
            return nil
        case nil:
            return nil
        }
    }

    private func start(_ key: Key) -> Task<Result<RegistrySchema, SchemaRegistryError>, Never> {
        state.withLock { state in
            if let running = state.inFlight[key] { return running }
            let task = Task { [endpoint, transport] in
                let result = await Self.fetch(key, endpoint: endpoint, transport: transport)
                self.finish(key, with: result)
                return result
            }
            state.inFlight[key] = task
            return task
        }
    }

    private func finish(_ key: Key, with result: Result<RegistrySchema, SchemaRegistryError>) {
        state.withLock { state in
            state.inFlight[key] = nil
            switch result {
            case .success(let schema): state.entries[key] = .loaded(schema)
            case .failure(let error): state.entries[key] = .failed(error, at: .now)
            }
        }
        NotificationCenter.default.post(
            name: Self.didLoadSchema, object: self, userInfo: [Self.connectionIDKey: key.connectionID]
        )
    }

    private static func fetch(
        _ key: Key,
        endpoint: EndpointProvider,
        transport: @escaping SchemaRegistryClient.Transport
    ) async -> Result<RegistrySchema, SchemaRegistryError> {
        guard let resolved = await endpoint(key.connectionID) else {
            return .failure(SchemaRegistryError(
                reason: String(localized: "The connection names no Schema Registry URL. Add one in the connection's settings.")
            ))
        }
        do {
            return .success(try await SchemaRegistryClient(endpoint: resolved, transport: transport).schema(id: key.schemaID))
        } catch let error as SchemaRegistryError {
            return .failure(error)
        } catch {
            return .failure(SchemaRegistryError(reason: error.localizedDescription))
        }
    }
}
