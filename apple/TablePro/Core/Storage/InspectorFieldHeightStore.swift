//
//  InspectorFieldHeightStore.swift
//  TablePro
//

import Combine
import Foundation

// Device-local. Keyed by column name alone, so a size holds on every row and in every result showing that column.
@MainActor
internal final class InspectorFieldHeightStore: ObservableObject {
    static let shared = InspectorFieldHeightStore()
    static let capacity = 200

    private static let key = PreferenceKeys.rowInspectorFieldHeights

    @Published private(set) var heights: [String: Double] = [:]
    // Least recently set first, so the oldest is dropped past `capacity`.
    private var order: [String] = []
    private let store: KeyValueStore

    init(defaults: KeyValueStore = AppStorageEnvironment.shared.defaults) {
        store = defaults
        reload()
    }

    func height(for column: String) -> Double? {
        heights[column]
    }

    func setHeight(_ height: Double, for column: String) {
        order.removeAll { $0 == column }
        order.append(column)
        var updated = heights
        updated[column] = height
        if order.count > Self.capacity {
            for evicted in order.prefix(order.count - Self.capacity) {
                updated[evicted] = nil
            }
            order.removeFirst(order.count - Self.capacity)
        }
        heights = updated
        persist()
    }

    func reload() {
        var loaded: [String: Double] = [:]
        var loadedOrder: [String] = []
        for entry in store.read(Self.key).value ?? [] {
            if loaded.updateValue(entry.height, forKey: entry.column) != nil {
                loadedOrder.removeAll { $0 == entry.column }
            }
            loadedOrder.append(entry.column)
        }
        order = loadedOrder
        heights = loaded
    }

    private func persist() {
        let entries = order.compactMap { column in heights[column].map { Entry(column: column, height: $0) } }
        try? store.write(entries, to: Self.key)
    }

    struct Entry: Codable {
        let column: String
        let height: Double
    }
}
