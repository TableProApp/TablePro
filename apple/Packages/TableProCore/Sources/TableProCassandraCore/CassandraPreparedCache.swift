//
//  CassandraPreparedCache.swift
//  TableProCassandraCore
//

import Foundation

// The prepared statements a session's browse pages reuse. A statement belongs to the schema snapshot it was prepared
// under, so the first statement prepared under a newer snapshot retires every older one.
public struct CassandraPreparedCache<Handle> {
    public struct Key: Hashable, Sendable {
        public let keyspace: String?
        public let cql: String
        public let schemaVersion: UInt32

        public init(keyspace: String?, cql: String, schemaVersion: UInt32) {
            self.keyspace = keyspace
            self.cql = cql
            self.schemaVersion = schemaVersion
        }
    }

    public let capacity: Int
    private var entries: [Key: Handle] = [:]
    private var recency: [Key] = []

    public init(capacity: Int = 16) {
        self.capacity = max(capacity, 1)
    }

    public var count: Int { entries.count }

    public mutating func handle(for key: Key) -> Handle? {
        guard let handle = entries[key] else { return nil }
        markRecent(key)
        return handle
    }

    // The handles the cache no longer holds, for the caller to release.
    public mutating func insert(_ handle: Handle, for key: Key) -> [Handle] {
        var released = recency
            .filter { $0.schemaVersion != key.schemaVersion }
            .compactMap { remove($0) }
        if let replaced = remove(key) {
            released.append(replaced)
        }
        entries[key] = handle
        recency.append(key)
        while recency.count > capacity, let oldest = recency.first, let evicted = remove(oldest) {
            released.append(evicted)
        }
        return released
    }

    public mutating func remove(_ key: Key) -> Handle? {
        recency.removeAll { $0 == key }
        return entries.removeValue(forKey: key)
    }

    public mutating func removeAll() -> [Handle] {
        let handles = Array(entries.values)
        entries = [:]
        recency = []
        return handles
    }

    private mutating func markRecent(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}

public enum CassandraPreparedReuse {
    // A reused statement decodes rows with the columns it was prepared with, so a select list that follows the table
    // (`*`) is prepared again for each read: a column added since would shift every value after it.
    public static func isReusable(cql: String) -> Bool {
        let scalars = Array(cql.unicodeScalars)
        var index = 0
        var inQuotes = false
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\"" {
                inQuotes.toggle()
            } else if !inQuotes {
                if scalar == "*" { return false }
                if startsFromKeyword(scalars, at: index) { return true }
            }
            index += 1
        }
        return false
    }

    private static func startsFromKeyword(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        let keyword = Array("FROM".unicodeScalars)
        guard index > 0, index + keyword.count < scalars.count,
              CharacterSet.whitespacesAndNewlines.contains(scalars[index - 1]),
              CharacterSet.whitespacesAndNewlines.contains(scalars[index + keyword.count])
        else { return false }
        return keyword.indices.allSatisfy { offset in
            String(scalars[index + offset]).uppercased() == String(keyword[offset])
        }
    }
}

extension CassandraPreparedCache: Sendable where Handle: Sendable {}
