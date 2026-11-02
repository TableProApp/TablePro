//
//  InspectorFieldHeightStore.swift
//  TablePro
//

import Combine
import Foundation
import os

// Device-local. Keyed by column name alone, so a size holds on every row and in every result showing that column.
@MainActor
internal final class InspectorFieldHeightStore: ObservableObject {
    static let shared = InspectorFieldHeightStore()
    static let capacity = 200

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "InspectorFieldHeightStore")
    private static let key = PreferenceKeys.rowInspectorFieldHeights.name

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
        for entry in store.dataValue(forKey: Self.key).flatMap(Self.decode) ?? [] {
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
        do {
            store.setDataValue(try JSONEncoder().encode(entries), forKey: Self.key)
        } catch {
            Self.logger.error("Could not save field heights: \(error.publicLogShape, privacy: .public)")
        }
    }

    private static func decode(_ data: Data) -> [Entry]? {
        do {
            return try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            logger.error("Discarding unreadable field heights: \(error.publicLogShape, privacy: .public)")
            return nil
        }
    }

    private struct Entry: Codable {
        let column: String
        let height: Double
    }
}
