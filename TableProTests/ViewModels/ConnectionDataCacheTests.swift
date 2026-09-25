//
//  ConnectionDataCacheTests.swift
//  TableProTests
//

import Combine
import Foundation
import Testing

@testable import TablePro

/// Issue #3016. The Favorites tab reads its whole Queries tree out of this cache, so the cache has
/// to outlive a tab switch and has to publish what it loads.
@MainActor
struct ConnectionDataCacheTests {
    private func snapshot(folderNamed name: String) -> ConnectionFavoritesSnapshot {
        ConnectionFavoritesSnapshot(folders: [SQLFavoriteFolder(name: name)])
    }

    // MARK: - Lifetime

    @Test("One connection gets one cache for as long as it is open")
    func sharedInstanceIsStableWhileTheConnectionIsOpen() {
        let connectionId = UUID()
        defer { ConnectionDataCache.removeConnection(connectionId) }

        let first = ConnectionDataCache.shared(for: connectionId)

        #expect(ConnectionDataCache.shared(for: connectionId) === first)
    }

    /// The warm-up at connection open used to drop its only reference inside the statement that
    /// made it, so the cache was gone before its own load could run.
    @Test("A cache nobody released survives with what it loaded")
    func aWarmedCacheKeepsItsContent() {
        let connectionId = UUID()
        defer { ConnectionDataCache.removeConnection(connectionId) }
        let cache = ConnectionDataCache.shared(for: connectionId)
        cache.commit(snapshot(folderNamed: "Reports"), generation: cache.nextRefreshGeneration())

        #expect(ConnectionDataCache.shared(for: connectionId).folders.map(\.name) == ["Reports"])
    }

    @Test("Closing a connection releases its cache")
    func removeConnectionReleasesTheCache() {
        let connectionId = UUID()
        let first = ConnectionDataCache.shared(for: connectionId)
        first.commit(snapshot(folderNamed: "Reports"), generation: first.nextRefreshGeneration())

        ConnectionDataCache.removeConnection(connectionId)
        defer { ConnectionDataCache.removeConnection(connectionId) }

        #expect(ConnectionDataCache.shared(for: connectionId).folders.isEmpty)
    }

    // MARK: - Refresh ordering

    /// A burst of iCloud favorite updates arrives as one event per record, so two reads of the same
    /// connection are routinely in flight at once. The one that started later holds the newer
    /// database, whichever of them comes back first.
    @Test("An overtaken read is dropped rather than published")
    func anOlderRefreshCannotOverwriteANewerOne() {
        let connectionId = UUID()
        defer { ConnectionDataCache.removeConnection(connectionId) }
        let cache = ConnectionDataCache.shared(for: connectionId)

        let older = cache.nextRefreshGeneration()
        let newer = cache.nextRefreshGeneration()

        cache.commit(snapshot(folderNamed: "Newer"), generation: newer)
        cache.commit(snapshot(folderNamed: "Older"), generation: older)

        #expect(cache.folders.map(\.name) == ["Newer"])
    }

    @Test("The newest read is published even when it finishes last")
    func theNewestRefreshStillCommits() {
        let connectionId = UUID()
        defer { ConnectionDataCache.removeConnection(connectionId) }
        let cache = ConnectionDataCache.shared(for: connectionId)

        let older = cache.nextRefreshGeneration()
        let newer = cache.nextRefreshGeneration()

        cache.commit(snapshot(folderNamed: "Older"), generation: older)
        cache.commit(snapshot(folderNamed: "Newer"), generation: newer)

        #expect(cache.folders.map(\.name) == ["Newer"])
    }

    @Test("A commit reports the initial load as finished")
    func aCommitCompletesTheInitialLoad() {
        let connectionId = UUID()
        defer { ConnectionDataCache.removeConnection(connectionId) }
        let cache = ConnectionDataCache.shared(for: connectionId)
        #expect(cache.isInitialLoadComplete == false)

        cache.commit(ConnectionFavoritesSnapshot(), generation: cache.nextRefreshGeneration())

        #expect(cache.isInitialLoadComplete)
    }

    @Test("An overtaken read does not report the initial load as finished")
    func anOvertakenCommitLeavesTheLoadOpen() {
        let connectionId = UUID()
        defer { ConnectionDataCache.removeConnection(connectionId) }
        let cache = ConnectionDataCache.shared(for: connectionId)

        let older = cache.nextRefreshGeneration()
        _ = cache.nextRefreshGeneration()
        cache.commit(ConnectionFavoritesSnapshot(), generation: older)

        #expect(cache.isInitialLoadComplete == false)
    }
}
