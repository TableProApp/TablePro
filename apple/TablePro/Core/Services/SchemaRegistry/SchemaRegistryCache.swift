//
//  SchemaRegistryCache.swift
//  TablePro
//

import Foundation
import os

// A registry never changes the schema behind an ID, so a loaded one is kept for the session, keyed by the endpoint it came from.
internal final class SchemaRegistryCache: Sendable {
    typealias Lookup = Result<RegistrySchema, SchemaRegistryError>
    typealias EndpointResolver = @MainActor @Sendable (UUID) -> SchemaRegistryEndpoint?

    static let shared = SchemaRegistryCache()

    // Posted once per batch that loaded a schema, and when a connection's endpoint changed.
    static let didChange = Notification.Name("com.TablePro.schemaRegistryCache.didChange")
    static let connectionIDKey = "connectionID"

    // A page of values can name thousands of IDs that are only bytes starting with zero, so fetches are bounded.
    static let maxConcurrentFetches = 4
    static let maxPendingFetches = 256
    static let maxFailures = 1_024

    private struct Key: Hashable {
        let endpoint: SchemaRegistryEndpoint
        let schemaID: UInt32
    }

    private enum Entry {
        case loaded(RegistrySchema)
        case failed(SchemaRegistryError, at: ContinuousClock.Instant)
    }

    private enum Resolved {
        case configured(SchemaRegistryEndpoint)
        case unconfigured
    }

    private struct State {
        var endpoints: [UUID: Resolved] = [:]
        var entries: [Key: Entry] = [:]
        var inFlight: [Key: Task<Lookup, Never>] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let resolveEndpoint: EndpointResolver
    private let transport: SchemaRegistryClient.Transport
    private let failureLifetime: Duration
    private let limiter = FetchLimiter(limit: SchemaRegistryCache.maxConcurrentFetches)

    init(
        failureLifetime: Duration = .seconds(30),
        resolveEndpoint: @escaping EndpointResolver = { SchemaRegistryEndpoint.resolve(for: $0) },
        transport: @escaping SchemaRegistryClient.Transport = SchemaRegistryClient.urlSessionTransport
    ) {
        self.failureLifetime = failureLifetime
        self.resolveEndpoint = resolveEndpoint
        self.transport = transport
    }

    // Never fetches: nil until a prefetch or the viewer has asked for the schema.
    func cachedSchema(connectionID: UUID, schemaID: UInt32) -> Lookup? {
        state.withLock { state in
            switch state.endpoints[connectionID] {
            case nil:
                return nil
            case .unconfigured?:
                return .failure(Self.noEndpoint)
            case .configured(let endpoint)?:
                switch state.entries[Key(endpoint: endpoint, schemaID: schemaID)] {
                case .loaded(let schema)?: return .success(schema)
                case .failed(let error, _)?: return .failure(error)
                case nil: return nil
                }
            }
        }
    }

    // A full reload retries failures at once; anything else waits out the failure lifetime.
    @MainActor
    func prefetch(connectionID: UUID, schemaIDs: Set<UInt32>, retryingFailures: Bool) {
        guard !schemaIDs.isEmpty else { return }
        let allLoaded = state.withLock { state -> Bool in
            guard case .configured(let endpoint)? = state.endpoints[connectionID] else { return false }
            return schemaIDs.allSatisfy {
                if case .loaded? = state.entries[Key(endpoint: endpoint, schemaID: $0)] { return true }
                return false
            }
        }
        // Resolving reads the Keychain, so a batch that needs nothing new skips it unless a reload asked to look again.
        if allLoaded, !retryingFailures { return }
        let endpoint = resolveEndpoint(connectionID)
        let (changed, pending) = state.withLock { state -> (Bool, [Task<Lookup, Never>]) in
            let changed = adopt(endpoint, for: connectionID, in: &state)
            guard let endpoint else { return (changed, []) }
            pruneFailures(in: &state)
            var pending: [Task<Lookup, Never>] = []
            for schemaID in schemaIDs.sorted() {
                let key = Key(endpoint: endpoint, schemaID: schemaID)
                if let running = state.inFlight[key] {
                    pending.append(running)
                } else if usable(state.entries[key], retryingFailures: retryingFailures) == nil,
                          state.inFlight.count < Self.maxPendingFetches {
                    pending.append(start(key, in: &state))
                }
            }
            return (changed, pending)
        }
        if changed { Self.post(connectionID) }
        guard !pending.isEmpty else { return }
        Task {
            var loaded = false
            for task in pending {
                if case .success = await task.value { loaded = true }
            }
            if loaded { Self.post(connectionID) }
        }
    }

    @MainActor
    func schema(connectionID: UUID, schemaID: UInt32) async -> Lookup {
        let endpoint = resolveEndpoint(connectionID)
        let (changed, pending, cached) = state.withLock { state -> (Bool, Task<Lookup, Never>?, Lookup?) in
            let changed = adopt(endpoint, for: connectionID, in: &state)
            guard let endpoint else { return (changed, nil, .failure(Self.noEndpoint)) }
            let key = Key(endpoint: endpoint, schemaID: schemaID)
            if let running = state.inFlight[key] { return (changed, running, nil) }
            if let cached = usable(state.entries[key], retryingFailures: false) { return (changed, nil, cached) }
            return (changed, start(key, in: &state), nil)
        }
        if changed { Self.post(connectionID) }
        guard let pending else { return cached ?? .failure(Self.noEndpoint) }
        let result = await pending.value
        if case .success = result { Self.post(connectionID) }
        return result
    }

    private static var noEndpoint: SchemaRegistryError {
        SchemaRegistryError(
            reason: String(localized: "The connection names no Schema Registry URL. Add one in the connection's settings.")
        )
    }

    private func adopt(_ endpoint: SchemaRegistryEndpoint?, for connectionID: UUID, in state: inout State) -> Bool {
        let resolved: Resolved = endpoint.map { .configured($0) } ?? .unconfigured
        let previous = state.endpoints.updateValue(resolved, forKey: connectionID)
        switch (previous, resolved) {
        case (nil, _), (.unconfigured?, .unconfigured):
            return false
        case (.configured(let old)?, .configured(let new)):
            return old != new
        default:
            return true
        }
    }

    private func usable(_ entry: Entry?, retryingFailures: Bool) -> Lookup? {
        switch entry {
        case .loaded(let schema)?:
            return .success(schema)
        case .failed(let error, let at)?:
            return retryingFailures || ContinuousClock.now - at >= failureLifetime ? nil : .failure(error)
        case nil:
            return nil
        }
    }

    private func start(_ key: Key, in state: inout State) -> Task<Lookup, Never> {
        let client = SchemaRegistryClient(endpoint: key.endpoint, transport: transport)
        let limiter = limiter
        let task = Task<Lookup, Never> {
            await limiter.acquire()
            let result: Lookup
            do {
                result = .success(try await client.schema(id: key.schemaID))
            } catch let error as SchemaRegistryError {
                result = .failure(error)
            } catch {
                result = .failure(SchemaRegistryError(reason: error.localizedDescription))
            }
            await limiter.release()
            self.finish(key, with: result)
            return result
        }
        state.inFlight[key] = task
        return task
    }

    private func finish(_ key: Key, with result: Lookup) {
        state.withLock { state in
            state.inFlight[key] = nil
            switch result {
            case .success(let schema): state.entries[key] = .loaded(schema)
            case .failure(let error): state.entries[key] = .failed(error, at: .now)
            }
        }
    }

    // Garbage prefixes would otherwise leave one failure each for the session.
    private func pruneFailures(in state: inout State) {
        let now = ContinuousClock.now
        var failures: [(key: Key, at: ContinuousClock.Instant)] = []
        for (key, entry) in state.entries {
            guard case .failed(_, let at) = entry else { continue }
            if now - at >= failureLifetime {
                state.entries[key] = nil
            } else {
                failures.append((key, at))
            }
        }
        guard failures.count > Self.maxFailures else { return }
        for failure in failures.sorted(by: { $0.at < $1.at }).prefix(failures.count - Self.maxFailures) {
            state.entries[failure.key] = nil
        }
    }

    private static func post(_ connectionID: UUID) {
        NotificationCenter.default.post(name: didChange, object: nil, userInfo: [connectionIDKey: connectionID])
    }
}

private actor FetchLimiter {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        guard running >= limit else {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        guard !waiting.isEmpty else {
            running -= 1
            return
        }
        waiting.removeFirst().resume()
    }
}
