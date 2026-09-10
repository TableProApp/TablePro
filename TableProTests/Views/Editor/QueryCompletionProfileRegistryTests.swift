import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class LeaseCountingMetadataProvider: ScopedMetadataProviding {
    private let driver: MockDatabaseDriver
    private let scope: DatabaseScope
    private(set) var leaseCount = 0

    init(driver: MockDatabaseDriver, browseScope: DatabaseScope) {
        self.driver = driver
        self.scope = browseScope
    }

    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        leaseCount += 1
        return try await body(driver)
    }

    func browseScope(for connectionId: UUID) -> DatabaseScope? { scope }
}

@Suite("Query completion profile registry")
@MainActor
struct QueryCompletionProfileRegistryTests {
    actor Counter {
        private(set) var value = 0

        func increment() {
            value += 1
        }
    }

    /// Lets one resolution announce that the registry has already recorded it as in flight,
    /// so the joining call is made against a known state instead of racing `async let` ordering.
    actor Signal {
        private var isRaised = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func raise() {
            isRaised = true
            for waiter in waiters {
                waiter.resume()
            }
            waiters = []
        }

        func wait() async {
            guard !isRaised else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    nonisolated private static func base(revision: String = "base") -> QueryCompletionProfile {
        QueryCompletionProfile(
            resolvedDialect: nil,
            statementCompletions: [CompletionEntry(label: "SELECT", insertText: "SELECT")],
            revision: revision
        )
    }

    @Test("a cached profile is served without leasing a metadata driver")
    func cachedProfileSkipsTheDriverLease() async {
        let registry = QueryCompletionProfileRegistry()
        let connectionId = UUID()
        let scope = DatabaseScope(connectionId: connectionId, database: "shop", schema: nil)
        let metadataProvider = LeaseCountingMetadataProvider(
            driver: MockDatabaseDriver(),
            browseScope: scope
        )

        _ = await registry.profile(for: scope, databaseType: .postgresql, metadataProvider: metadataProvider)
        _ = await registry.profile(for: scope, databaseType: .postgresql, metadataProvider: metadataProvider)

        #expect(metadataProvider.leaseCount == 1)

        registry.invalidate(scope: scope)
        _ = await registry.profile(for: scope, databaseType: .postgresql, metadataProvider: metadataProvider)

        #expect(metadataProvider.leaseCount == 2)
    }

    @Test("cache keys separate scope and database type")
    func cacheKeySeparatesScopeAndType() async {
        let registry = QueryCompletionProfileRegistry()
        let connectionId = UUID()
        let firstScope = DatabaseScope(connectionId: connectionId, database: "first", schema: "public")
        let secondScope = DatabaseScope(connectionId: connectionId, database: "second", schema: "public")
        let resolutions = Counter()

        _ = await registry.resolve(scope: firstScope, databaseType: .postgresql, base: Self.base()) {
            await resolutions.increment()
            return Self.base(revision: "first")
        }
        _ = await registry.resolve(scope: firstScope, databaseType: .postgresql, base: Self.base()) {
            await resolutions.increment()
            return Self.base(revision: "cached")
        }
        _ = await registry.resolve(scope: secondScope, databaseType: .postgresql, base: Self.base()) {
            await resolutions.increment()
            return Self.base(revision: "second")
        }
        _ = await registry.resolve(scope: firstScope, databaseType: .cockroachdb, base: Self.base()) {
            await resolutions.increment()
            return Self.base(revision: "type")
        }

        #expect(await resolutions.value == 3)
    }

    /// The behaviour this suite previously asserted the opposite of. Caching a thrown resolution
    /// is permanent, because nothing re-resolves a key the cache already holds: one unlucky
    /// metadata read would pin the tab to the app's built-in dialect until a manual refresh.
    @Test("a failed resolution returns the base profile without caching it")
    func resolutionFailureReturnsBaseAndDoesNotCache() async {
        let registry = QueryCompletionProfileRegistry()
        let scope = DatabaseScope(connectionId: UUID(), database: "shop", schema: nil)
        let conservative = Self.base(revision: "unknown-base")
        let attempts = Counter()

        let failed = await registry.resolve(scope: scope, databaseType: .mysql, base: conservative) {
            await attempts.increment()
            throw DatabaseError.connectionFailed("catalog denied")
        }

        #expect(failed.revision == "unknown-base")
        #expect(failed.statementCompletions.map(\.label) == ["SELECT"])

        let retried = await registry.resolve(scope: scope, databaseType: .mysql, base: conservative) {
            await attempts.increment()
            return Self.base(revision: "recovered")
        }

        #expect(await attempts.value == 2)
        #expect(retried.revision == "recovered")
    }

    @Test("a recovered resolution is cached, so the retry does not repeat forever")
    func recoveredResolutionIsCached() async {
        let registry = QueryCompletionProfileRegistry()
        let scope = DatabaseScope(connectionId: UUID(), database: "shop", schema: nil)
        let attempts = Counter()

        _ = await registry.resolve(scope: scope, databaseType: .mysql, base: Self.base()) {
            await attempts.increment()
            throw DatabaseError.connectionFailed("catalog denied")
        }
        _ = await registry.resolve(scope: scope, databaseType: .mysql, base: Self.base()) {
            await attempts.increment()
            return Self.base(revision: "recovered")
        }
        let third = await registry.resolve(scope: scope, databaseType: .mysql, base: Self.base()) {
            await attempts.increment()
            return Self.base(revision: "should-not-run")
        }

        #expect(await attempts.value == 2)
        #expect(third.revision == "recovered")
    }

    @Test("concurrent requests for one key join one resolution")
    func concurrentRequestsJoinOneResolution() async {
        let registry = QueryCompletionProfileRegistry()
        let scope = DatabaseScope(connectionId: UUID(), database: "shop", schema: nil)
        let resolutions = Counter()

        let didStart = Signal()
        let mayFinish = Signal()

        async let first = registry.resolve(scope: scope, databaseType: .mysql, base: Self.base()) {
            await resolutions.increment()
            await didStart.raise()
            await mayFinish.wait()
            return Self.base(revision: "resolved")
        }
        await didStart.wait()
        async let second = registry.resolve(scope: scope, databaseType: .mysql, base: Self.base()) {
            await resolutions.increment()
            return Self.base(revision: "duplicate")
        }
        await mayFinish.raise()

        let revisions = await [first.revision, second.revision]
        #expect(await resolutions.value == 1)
        #expect(revisions == ["resolved", "resolved"])
    }

    /// Cancelling a caller that awaits a shared `Task.value` neither cancels that task nor returns
    /// early, measured, so a superseded resolution always runs its tail to the commit. Refusing to
    /// cache is only half the guard: the stale value must not reach the caller either, because the
    /// caller configures the editor with whatever it is handed.
    @Test("invalidation prevents an old resolution from replacing or being returned by the next generation")
    func invalidationFencesOldResolution() async {
        let registry = QueryCompletionProfileRegistry()
        let scope = DatabaseScope(connectionId: UUID(), database: "shop", schema: nil)

        async let old = registry.resolve(scope: scope, databaseType: .mysql, base: Self.base()) {
            try? await Task.sleep(nanoseconds: 10_000_000)
            return Self.base(revision: "old")
        }
        await Task.yield()
        registry.invalidate(scope: scope)
        let current = await registry.resolve(scope: scope, databaseType: .mysql, base: Self.base()) {
            Self.base(revision: "current")
        }
        let fenced = await old
        let cached = await registry.resolve(scope: scope, databaseType: .mysql, base: Self.base()) {
            Self.base(revision: "unexpected")
        }

        #expect(current.revision == "current")
        #expect(cached.revision == "current")
        #expect(fenced.revision != "old")
    }

    /// Observation's granularity is the whole stored property, so a `[Scope: Int]` on an
    /// `@Observable` registry would make one scope's refresh re-evaluate every editor body on the
    /// connection. Separate boxes are what keep a bump local to the scope that was invalidated.
    @Test("invalidating one scope leaves a sibling scope's revision alone")
    func revisionBumpsStayLocalToTheirScope() {
        let registry = QueryCompletionProfileRegistry()
        let connectionId = UUID()
        let first = DatabaseScope(connectionId: connectionId, database: "first", schema: nil)
        let second = DatabaseScope(connectionId: connectionId, database: "second", schema: nil)

        let firstBox = registry.revisionBox(for: first)
        let secondBox = registry.revisionBox(for: second)
        #expect(firstBox.revision == 0)
        #expect(secondBox.revision == 0)

        registry.invalidate(scope: first)

        #expect(firstBox.revision == 1)
        #expect(secondBox.revision == 0)
    }

    @Test("the same scope always gets the same revision box, so a rebuilt body keeps observing")
    func revisionBoxIsStablePerScope() {
        let registry = QueryCompletionProfileRegistry()
        let scope = DatabaseScope(connectionId: UUID(), database: "shop", schema: nil)

        let first = registry.revisionBox(for: scope)
        let second = registry.revisionBox(for: scope)

        #expect(first === second)
    }

    /// Teardown must not rewind the fence. `clear` used to remove the generations it had just
    /// bumped, so a resolution still blocked inside the metadata lease resumed, re-read its key as
    /// generation 0, matched the 0 it had captured, and wrote a profile from the closed session
    /// into the cache disconnect had just emptied. The next connection's scope keys are identical,
    /// so it would have been served that profile.
    @Test("a resolution in flight when the connection is cleared cannot write into the cache")
    func clearFencesAnInFlightResolution() async {
        let registry = QueryCompletionProfileRegistry()
        let connectionId = UUID()
        let scope = DatabaseScope(connectionId: connectionId, database: "shop", schema: nil)

        let didStart = Signal()
        let mayFinish = Signal()

        async let inFlight = registry.resolve(scope: scope, databaseType: .mysql, base: Self.base()) {
            await didStart.raise()
            await mayFinish.wait()
            return Self.base(revision: "from-the-closed-session")
        }
        await didStart.wait()
        registry.clear(connectionId: connectionId)
        await mayFinish.raise()
        _ = await inFlight

        let afterReconnect = await registry.resolve(scope: scope, databaseType: .mysql, base: Self.base()) {
            Self.base(revision: "fresh")
        }

        #expect(afterReconnect.revision == "fresh")
    }

    @Test("invalidating a connection bumps every scope it holds")
    func connectionInvalidationBumpsEveryScope() {
        let registry = QueryCompletionProfileRegistry()
        let connectionId = UUID()
        let other = UUID()
        let first = DatabaseScope(connectionId: connectionId, database: "first", schema: nil)
        let second = DatabaseScope(connectionId: connectionId, database: "second", schema: nil)
        let foreign = DatabaseScope(connectionId: other, database: "first", schema: nil)

        let firstBox = registry.revisionBox(for: first)
        let secondBox = registry.revisionBox(for: second)
        let foreignBox = registry.revisionBox(for: foreign)

        registry.invalidate(connectionId: connectionId)

        #expect(firstBox.revision == 1)
        #expect(secondBox.revision == 1)
        #expect(foreignBox.revision == 0)
    }
}
