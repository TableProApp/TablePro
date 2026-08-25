import Combine
import Foundation
import Observation
import TableProPluginKit

/// One scope's invalidation counter, as its own observable object.
///
/// The counter cannot live in a dictionary on an `@Observable` registry. Observation's
/// granularity is the whole stored property: the generated getter emits
/// `access(keyPath: \.revisions)` and `ObservationRegistrar.access` takes a `KeyPath`, with no
/// per-subscript form. A `revision(for:)` helper therefore registers a dependency on the entire
/// dictionary, so one scope's bump re-evaluates every editor body on the connection. Worse,
/// `dict[key, default: 0] &+= 1` mutates through the ungated `_modify` accessor and notifies even
/// when the value did not change; only whole-dictionary assignment gets the equality gate.
///
/// A non-observable container holding observable leaves gives real per-scope granularity, which is
/// the shape `SchemaProviderRegistry` already uses for its providers.
@MainActor
@Observable
final class QueryCompletionRevisionBox {
    private(set) var revision = 0

    func bump() {
        revision &+= 1
    }
}

/// Caches the resolved completion profile for a scope, and tells the editor when to ask again.
///
/// Deliberately not `@Observable`: everything a view observes here is a `QueryCompletionRevisionBox`,
/// for the reason written on that type.
@MainActor
final class QueryCompletionProfileRegistry {
    struct CacheKey: Hashable {
        let scope: DatabaseScope
        let databaseType: DatabaseType
    }

    static let shared = QueryCompletionProfileRegistry()

    private var profiles: [CacheKey: QueryCompletionProfile] = [:]
    private var inFlight: [CacheKey: Task<QueryCompletionProfile?, Never>] = [:]
    private var generations: [CacheKey: Int] = [:]
    private var revisionBoxes: [DatabaseScope: QueryCompletionRevisionBox] = [:]
    private var cancellables: Set<AnyCancellable> = []

    #if DEBUG
    /// Test-only init for `@testable` tests in DEBUG builds; release builds must use `.shared`.
    /// A second instance in shipping code is a second profile cache no `invalidate` call reaches,
    /// plus a second permanent `refreshData` subscription.
    internal init() {
        subscribeToRefreshSignal()
    }
    #else
    private init() {
        subscribeToRefreshSignal()
    }
    #endif

    private func subscribeToRefreshSignal() {
        AppCommands.shared.refreshData
            .sink { [weak self] request in
                guard let self else { return }
                if let scope = request.scope {
                    self.invalidate(scope: scope)
                } else {
                    self.invalidate(connectionId: request.connectionId)
                }
            }
            .store(in: &cancellables)
    }

    /// The box a view keys its `.task(id:)` on. Creating one is invisible to SwiftUI, because the
    /// registry itself is not observable, so calling this from a body registers a dependency on
    /// the box's `revision` alone.
    func revisionBox(for scope: DatabaseScope) -> QueryCompletionRevisionBox {
        if let existing = revisionBoxes[scope] { return existing }
        let box = QueryCompletionRevisionBox()
        revisionBoxes[scope] = box
        return box
    }

    /// The metadata driver is leased inside the resolver rather than around this call, so a
    /// cached profile costs nothing. An engine that cannot pool serves metadata from the
    /// session driver, and leasing that for a profile the cache already holds would queue
    /// behind, and ahead of, the statements the user is running.
    ///
    /// The server version is deliberately not part of the key. It changes only across a reconnect,
    /// and `clear(connectionId:)` already empties the cache on disconnect. Keying on it meant
    /// reading it from a SwiftUI body through `DatabaseManager.driver(for:)`, and
    /// `PluginDriverAdapter` is not observable, so a version learned after connect reached no
    /// body and the profile stayed cached under a nil-version key for the life of the tab.
    func profile(
        for scope: DatabaseScope,
        databaseType: DatabaseType,
        metadataProvider: any ScopedMetadataProviding = DatabaseManager.shared
    ) async -> QueryCompletionProfile {
        let base = baseProfile(for: databaseType)
        return await resolve(
            scope: scope,
            databaseType: databaseType,
            base: base
        ) {
            try await metadataProvider.withMetadataDriver(scope: scope) { driver in
                try await driver.resolveQueryCompletionProfile(
                    databaseTypeId: databaseType.rawValue,
                    base: base
                )
            }
        }
    }

    /// Resolves once per key, joining any resolution already in flight.
    ///
    /// A resolver that throws is answered with `base` and **nothing is cached**, so the next run
    /// tries again. Caching the fallback would be permanent: nothing re-resolves a key the cache
    /// already holds, so one unlucky metadata read would pin the tab to the app's built-in dialect
    /// until the user pressed Refresh. Leaving it uncached costs nothing, because SwiftUI re-runs
    /// a `.task` at an unchanged id whenever its host view is unparented and reparented, which is
    /// what every connection switch does.
    func resolve(
        scope: DatabaseScope,
        databaseType: DatabaseType,
        base: QueryCompletionProfile,
        resolver: @Sendable @escaping () async throws -> QueryCompletionProfile
    ) async -> QueryCompletionProfile {
        let key = CacheKey(scope: scope, databaseType: databaseType)
        if let profile = profiles[key] {
            return profile
        }
        let generation = generations[key, default: 0]
        if let task = inFlight[key] {
            let joined = await task.value
            guard generations[key, default: 0] == generation else { return base }
            return joined ?? base
        }
        let task = Task { try? await resolver() }
        inFlight[key] = task
        let resolved = await task.value

        /// Checked after the await, never before: cancelling a caller that is awaiting a shared
        /// `Task.value` neither cancels that task nor returns early, so a superseded resolution
        /// always runs its tail all the way to this line. Refusing to cache is half the guard;
        /// the stale value must not be returned to this caller either, because the caller
        /// configures the editor with whatever it gets back.
        guard generations[key, default: 0] == generation else { return base }
        inFlight.removeValue(forKey: key)
        guard let resolved else { return base }
        profiles[key] = resolved
        return resolved
    }

    func invalidate(scope: DatabaseScope) {
        revisionBoxes[scope]?.bump()
        discardEntries { $0 == scope }
    }

    func invalidate(connectionId: UUID) {
        for (scope, box) in revisionBoxes where scope.connectionId == connectionId {
            box.bump()
        }
        discardEntries { $0.connectionId == connectionId }
    }

    /// Teardown, as opposed to invalidation. A box has to keep counting up while its connection is
    /// open, because the editor's `.task(id:)` keys on it and a value that went backwards would
    /// re-fire the wrong way round. Once the session is gone there is nothing left to key.
    func clear(connectionId: UUID) {
        discardEntries { $0.connectionId == connectionId }
        /// `generations` is deliberately not cleared. `discardEntries` has just bumped every key
        /// it matched, and that bump is the only thing stopping a resolution still blocked inside
        /// `withMetadataDriver` from committing: the lease body never checks cancellation, so it
        /// resumes after this call and re-reads its key. Removing the entry would make
        /// `generations[key, default: 0]` answer 0 again, the captured generation would match, and
        /// a profile from the closed session would be written into the emptied cache and then
        /// served to the next connection, whose scope keys are identical.
        ///
        /// A counter per scope and type visited on one connection is a bounded cost; rewinding it
        /// is a correctness bug.
        for scope in Array(revisionBoxes.keys) where scope.connectionId == connectionId {
            revisionBoxes.removeValue(forKey: scope)
        }
    }

    /// The generation bump is what fences a resolution that is already running: it completes
    /// against a key whose generation moved, so it discards its own result instead of writing
    /// a profile the refresh was meant to replace.
    private func discardEntries(matching matches: (DatabaseScope) -> Bool) {
        for key in profiles.keys where matches(key.scope) {
            generations[key, default: 0] &+= 1
        }
        for key in Array(inFlight.keys) where matches(key.scope) {
            generations[key, default: 0] &+= 1
            inFlight.removeValue(forKey: key)?.cancel()
        }
        profiles = profiles.filter { !matches($0.key.scope) }
    }

    private func baseProfile(for databaseType: DatabaseType) -> QueryCompletionProfile {
        QueryCompletionProfile(
            resolvedDialect: PluginManager.shared.sqlDialect(for: databaseType),
            statementCompletions: PluginManager.shared.statementCompletions(for: databaseType),
            revision: [databaseType.rawValue, "base"].joined(separator: ":")
        )
    }
}
