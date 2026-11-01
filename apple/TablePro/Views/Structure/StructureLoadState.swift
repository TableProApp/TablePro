//
//  StructureLoadState.swift
//  TablePro
//

import Foundation

// What a structure tab has read, what a refresh made stale, and which read failed, per part. A failed read keeps
// what was loaded before it and is reported where that part shows, never over the whole tab.
struct StructureLoadState: Equatable {
    enum Item: Hashable, CaseIterable {
        case columns
        case indexes
        case foreignKeys
        case checkConstraints
        case triggers
        case ddl

        init(_ section: StructureSection) {
            switch section {
            case .columns: self = .columns
            case .indexes: self = .indexes
            case .foreignKeys: self = .foreignKeys
            case .checkConstraints: self = .checkConstraints
            }
        }
    }

    private var loaded: Set<Item> = []
    private var stale: Set<Item> = []
    private(set) var failures: [Item: String] = [:]

    func hasData(_ item: Item) -> Bool {
        loaded.contains(item)
    }

    func needsFetch(_ item: Item) -> Bool {
        !loaded.contains(item) || stale.contains(item) || failures[item] != nil
    }

    func failure(_ item: Item) -> String? {
        failures[item]
    }

    mutating func markAllStale() {
        stale = loaded
    }

    mutating func markFetched(_ item: Item) {
        loaded.insert(item)
        stale.remove(item)
        failures.removeValue(forKey: item)
    }

    mutating func markFailed(_ item: Item, message: String) {
        failures[item] = message
    }

    mutating func reset() {
        loaded.removeAll()
        stale.removeAll()
        failures.removeAll()
    }
}
