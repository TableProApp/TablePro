//
//  CassandraRecentEntries.swift
//  TableProCassandraCore
//

import Foundation

// At most `capacity` entries in two halves. When the newer half is full the older half is dropped whole, so the
// entries written longest ago go first and no write costs more than a dictionary insert.
public struct CassandraRecentEntries<Key: Hashable, Value> {
    public let capacity: Int
    private var newer: [Key: Value] = [:]
    private var older: [Key: Value] = [:]

    public init(capacity: Int) {
        self.capacity = max(capacity, 2)
    }

    public subscript(key: Key) -> Value? {
        newer[key] ?? older[key]
    }

    public var count: Int {
        newer.count + older.count
    }

    public mutating func set(_ value: Value, for key: Key) {
        older.removeValue(forKey: key)
        if newer[key] == nil, newer.count >= capacity / 2 {
            older = newer
            newer = [:]
        }
        newer[key] = value
    }

    public mutating func removeValue(for key: Key) {
        newer.removeValue(forKey: key)
        older.removeValue(forKey: key)
    }

    public mutating func removeAll() {
        newer = [:]
        older = [:]
    }
}

extension CassandraRecentEntries: Sendable where Key: Sendable, Value: Sendable {}
