//
//  QuickSwitcherFrecencyStore.swift
//  TablePro
//

import Foundation

internal struct QuickSwitcherFrecencyStore {
    private struct RecencyBucket {
        let maxAge: TimeInterval
        let weight: Double
    }

    private static let keyPrefix = "QuickSwitcher.frecency."
    private static let legacyMRUKeyPrefix = "QuickSwitcher.mru."
    private static let maxSamplesPerItem = 10
    private static let maxTrackedItems = 100
    private static let maxBucketWeight: Double = 100

    private static let recencyBuckets: [RecencyBucket] = [
        RecencyBucket(maxAge: 4 * 86_400, weight: 100),
        RecencyBucket(maxAge: 14 * 86_400, weight: 70),
        RecencyBucket(maxAge: 31 * 86_400, weight: 50),
        RecencyBucket(maxAge: 90 * 86_400, weight: 30)
    ]
    private static let olderThanBucketsWeight: Double = 10

    private let defaults: UserDefaults
    private let key: String
    private let legacyKey: String

    init(connectionId: UUID, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = Self.keyPrefix + connectionId.uuidString
        self.legacyKey = Self.legacyMRUKeyPrefix + connectionId.uuidString
    }

    func recordAccess(itemId: String, at date: Date = Date()) {
        var accesses = loadAccesses()
        var samples = accesses[itemId] ?? []
        samples.append(date.timeIntervalSince1970)
        if samples.count > Self.maxSamplesPerItem {
            samples.removeFirst(samples.count - Self.maxSamplesPerItem)
        }
        accesses[itemId] = samples
        if accesses.count > Self.maxTrackedItems {
            prune(&accesses)
        }
        defaults.set(accesses, forKey: key)
    }

    func scores(now: Date = Date()) -> [String: Double] {
        loadAccesses().mapValues { score(for: $0, now: now) }
    }

    func recentItemIds(limit: Int) -> [String] {
        loadAccesses()
            .compactMap { itemId, samples in samples.max().map { (itemId, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    func clearHistory() {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: legacyKey)
    }

    private func score(for samples: [TimeInterval], now: Date) -> Double {
        let reference = now.timeIntervalSince1970
        let total = samples.reduce(0.0) { sum, sample in
            let age = reference - sample
            let weight = Self.recencyBuckets.first { age <= $0.maxAge }?.weight
                ?? Self.olderThanBucketsWeight
            return sum + weight
        }
        return min(1, total / (Double(Self.maxSamplesPerItem) * Self.maxBucketWeight))
    }

    private func loadAccesses() -> [String: [TimeInterval]] {
        if let stored = defaults.dictionary(forKey: key) as? [String: [TimeInterval]] {
            return stored
        }
        return migrateLegacyMRU()
    }

    private func migrateLegacyMRU() -> [String: [TimeInterval]] {
        guard let legacy = defaults.stringArray(forKey: legacyKey), !legacy.isEmpty else {
            return [:]
        }
        let now = Date().timeIntervalSince1970
        var accesses: [String: [TimeInterval]] = [:]
        for (index, itemId) in legacy.enumerated() {
            accesses[itemId] = [now - TimeInterval(index * 60)]
        }
        defaults.set(accesses, forKey: key)
        defaults.removeObject(forKey: legacyKey)
        return accesses
    }

    private func prune(_ accesses: inout [String: [TimeInterval]]) {
        let kept = accesses
            .sorted { ($0.value.max() ?? 0) > ($1.value.max() ?? 0) }
            .prefix(Self.maxTrackedItems)
        accesses = Dictionary(uniqueKeysWithValues: Array(kept))
    }
}
