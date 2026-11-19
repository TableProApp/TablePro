import Foundation
import TableProSQLQuoting

// A browse as the plugin writes it: `*` or quoted columns with TTL() selectors, read from one table, then an
// optional WHERE clause. Anything else is not a browse this type reads.
public struct CassandraBrowseSource: Equatable, Sendable {
    // Nil for `*`.
    public let selectors: [String]?
    public let keyspace: String?
    public let table: String
    public let tail: String

    public init?(cql: String) {
        var rest = Substring(cql).unicodeScalars
        guard Self.consume("SELECT ", from: &rest) else { return nil }
        if Self.consume("* ", from: &rest) {
            selectors = nil
        } else {
            var parsed: [String] = []
            repeat {
                guard let selector = Self.selector(from: &rest) else { return nil }
                parsed.append(selector)
            } while Self.consume(", ", from: &rest)
            guard Self.consume(" ", from: &rest) else { return nil }
            selectors = parsed
        }
        guard Self.consume("FROM ", from: &rest), let first = Self.quotedName(from: &rest) else { return nil }
        if Self.consume(".", from: &rest) {
            guard let second = Self.quotedName(from: &rest) else { return nil }
            keyspace = first
            table = second
        } else {
            keyspace = nil
            table = first
        }
        let remainder = String(Substring(rest))
        guard remainder.isEmpty || remainder.hasPrefix(" WHERE ") else { return nil }
        tail = remainder
    }

    // Prepared statements bind their table when prepared, so only a read that names its keyspace and its columns
    // reads the same rows, in the same shape, every time it is reused.
    public var isReusable: Bool {
        keyspace != nil && selectors != nil
    }

    public func qualified(in keyspace: String) -> String {
        let list = selectors?.joined(separator: ", ") ?? "*"
        return "SELECT \(list) FROM \(SQLQuoting.identifier(keyspace)).\(SQLQuoting.identifier(table))\(tail)"
    }

    private static func selector(from rest: inout Substring.UnicodeScalarView) -> String? {
        let wrapped = consume("TTL(", from: &rest)
        guard let name = quotedName(from: &rest) else { return nil }
        guard wrapped else { return SQLQuoting.identifier(name) }
        guard consume(")", from: &rest) else { return nil }
        return "TTL(\(SQLQuoting.identifier(name)))"
    }

    private static func consume(_ text: String, from rest: inout Substring.UnicodeScalarView) -> Bool {
        guard rest.starts(with: text.unicodeScalars) else { return false }
        rest = rest.dropFirst(text.unicodeScalars.count)
        return true
    }

    // A double-quoted identifier, `""` standing for one quote, as SQLQuoting.identifier writes it.
    private static func quotedName(from rest: inout Substring.UnicodeScalarView) -> String? {
        guard consume("\"", from: &rest) else { return nil }
        var name = String.UnicodeScalarView()
        while let scalar = rest.first {
            rest = rest.dropFirst()
            guard scalar == "\"" else {
                name.append(scalar)
                continue
            }
            guard consume("\"", from: &rest) else { return String(name) }
            name.append(scalar)
        }
        return nil
    }
}

// The prepared browses a session reuses, least recently used first out. A statement belongs to the schema snapshot
// it was prepared under, so the first one prepared under a newer snapshot retires every older one.
public struct CassandraPreparedCache<Handle> {
    public struct Key: Hashable, Sendable {
        public let cql: String
        public let schemaVersion: UInt32

        public init(cql: String, schemaVersion: UInt32) {
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
        recency.removeAll { $0 == key }
        recency.append(key)
        return handle
    }

    // Returns the handles the cache let go of, for the caller to free.
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
}

extension CassandraPreparedCache: Sendable where Handle: Sendable {}
