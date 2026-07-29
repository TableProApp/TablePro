//
//  QuickSwitcherFrecencyStoreTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct QuickSwitcherFrecencyStoreTests {
    private func makeDefaults() -> UserDefaults {
        guard let suite = UserDefaults(suiteName: "QuickSwitcherFrecencyTests.\(UUID().uuidString)") else {
            return .standard
        }
        return suite
    }

    private func makeStore(
        connectionId: UUID = UUID(),
        defaults: UserDefaults? = nil
    ) -> (store: QuickSwitcherFrecencyStore, defaults: UserDefaults, connectionId: UUID) {
        let suite = defaults ?? makeDefaults()
        let id = connectionId
        return (QuickSwitcherFrecencyStore(connectionId: id, defaults: suite), suite, id)
    }

    @Test("recordAccess produces a positive score")
    func recordAccessProducesScore() {
        let (store, _, _) = makeStore()
        store.recordAccess(itemId: "table_users")
        let score = store.scores()["table_users"] ?? 0
        #expect(score > 0)
    }

    @Test("Unknown items have no score entry")
    func unknownItemHasNoScore() {
        let (store, _, _) = makeStore()
        #expect(store.scores()["missing"] == nil)
    }

    @Test("Recent access scores higher than an old access")
    func recentBeatsOld() {
        let (store, _, _) = makeStore()
        let now = Date()
        store.recordAccess(itemId: "recent", at: now)
        store.recordAccess(itemId: "old", at: now.addingTimeInterval(-120 * 86_400))
        let scores = store.scores(now: now)
        #expect((scores["recent"] ?? 0) > (scores["old"] ?? 0))
    }

    @Test("Frequent access scores higher than a single access")
    func frequentBeatsSingle() {
        let (store, _, _) = makeStore()
        let now = Date()
        for offset in 0..<5 {
            store.recordAccess(itemId: "frequent", at: now.addingTimeInterval(TimeInterval(-offset * 3_600)))
        }
        store.recordAccess(itemId: "single", at: now)
        let scores = store.scores(now: now)
        #expect((scores["frequent"] ?? 0) > (scores["single"] ?? 0))
    }

    @Test("Score is capped at 1")
    func scoreCapsAtOne() {
        let (store, _, _) = makeStore()
        let now = Date()
        for offset in 0..<20 {
            store.recordAccess(itemId: "hot", at: now.addingTimeInterval(TimeInterval(-offset)))
        }
        #expect((store.scores(now: now)["hot"] ?? 0) <= 1)
    }

    @Test("Samples per item are capped at 10")
    func samplesCapPerItem() {
        let (store, defaults, connectionId) = makeStore()
        for offset in 0..<15 {
            store.recordAccess(itemId: "busy", at: Date().addingTimeInterval(TimeInterval(offset)))
        }
        let key = "QuickSwitcher.frecency.\(connectionId.uuidString)"
        let stored = defaults.dictionary(forKey: key) as? [String: [TimeInterval]]
        #expect(stored?["busy"]?.count == 10)
    }

    @Test("Tracked items are pruned to the most recently used 100")
    func trackedItemsPruned() {
        let (store, _, _) = makeStore()
        let now = Date()
        for index in 0..<120 {
            store.recordAccess(itemId: "item_\(index)", at: now.addingTimeInterval(TimeInterval(index)))
        }
        let scores = store.scores(now: now)
        #expect(scores.count == 100)
        #expect(scores["item_119"] != nil)
        #expect(scores["item_0"] == nil)
    }

    @Test("recentItemIds orders by last access, newest first")
    func recentItemIdsOrdered() {
        let (store, _, _) = makeStore()
        let now = Date()
        store.recordAccess(itemId: "first", at: now.addingTimeInterval(-300))
        store.recordAccess(itemId: "second", at: now.addingTimeInterval(-200))
        store.recordAccess(itemId: "third", at: now.addingTimeInterval(-100))
        #expect(store.recentItemIds(limit: 2) == ["third", "second"])
    }

    @Test("Legacy MRU list migrates preserving order and removes the old key")
    func legacyMRUMigrates() {
        let suite = makeDefaults()
        let connectionId = UUID()
        let legacyKey = "QuickSwitcher.mru.\(connectionId.uuidString)"
        suite.set(["newest", "middle", "oldest"], forKey: legacyKey)

        let store = QuickSwitcherFrecencyStore(connectionId: connectionId, defaults: suite)
        #expect(store.recentItemIds(limit: 10) == ["newest", "middle", "oldest"])
        #expect(suite.stringArray(forKey: legacyKey) == nil)
    }

    @Test("clearHistory removes all tracked accesses")
    func clearHistoryRemovesAll() {
        let (store, _, _) = makeStore()
        store.recordAccess(itemId: "table_users")
        store.clearHistory()
        #expect(store.scores().isEmpty)
        #expect(store.recentItemIds(limit: 10).isEmpty)
    }

    @Test("Stores for different connections are isolated")
    func storesAreIsolatedPerConnection() {
        let suite = makeDefaults()
        let storeA = QuickSwitcherFrecencyStore(connectionId: UUID(), defaults: suite)
        let storeB = QuickSwitcherFrecencyStore(connectionId: UUID(), defaults: suite)
        storeA.recordAccess(itemId: "table_users")
        #expect(storeB.scores().isEmpty)
    }
}
