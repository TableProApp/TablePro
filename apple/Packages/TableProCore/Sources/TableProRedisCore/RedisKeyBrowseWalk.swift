import Foundation

/// A key browse walked forward from a saved SCAN cursor, so the next page continues where the last one stopped
/// instead of scanning the keyspace again from the start.
///
/// SCAN returns keys in hash table order and may return a key twice, so the walk keeps every key it has seen, once,
/// in the order the pages were loaded. Each load is sorted on its own and appended: the rows of a page already shown
/// keep their place, and the order on screen covers the loaded keys only, which the status says.
nonisolated public struct RedisKeyBrowseWalk: Sendable {
    /// What the walk lists: one database, MATCH pattern and TYPE. Any other scope is a new walk.
    public struct Scope: Hashable, Sendable {
        public let database: Int
        public let pattern: String?
        public let type: String?

        public init(database: Int, pattern: String?, type: String?) {
            self.database = database
            self.pattern = pattern
            self.type = type
        }
    }

    public let scope: Scope
    public private(set) var cursor: String = RedisClusterCursor.start
    public private(set) var keys: [String] = []
    public private(set) var isComplete = false
    /// The offset of the page the walk last served. The same page asked for again is a reload, which starts over.
    public var servedOffset: Int?
    private var seen: Set<String> = []
    private var loadStart = 0

    public init(scope: Scope) {
        self.scope = scope
    }

    /// Whether a page at `offset` continues this walk: a later or an earlier page does, the first page and the page
    /// already on screen, which a refresh and a changed filter ask for, start a new one.
    public func continues(atOffset offset: Int) -> Bool {
        offset > 0 && offset != servedOffset
    }

    /// Whether a page ending at `end` needs more keys than the walk holds and the keyspace may still have them.
    public func needsKeys(through end: Int) -> Bool {
        !isComplete && keys.count < end
    }

    /// One SCAN reply. The server answers the start cursor once the walk is over.
    public mutating func absorb(keys page: [String], nextCursor: String) {
        for key in page where seen.insert(key).inserted {
            keys.append(key)
        }
        cursor = nextCursor
        if nextCursor == RedisClusterCursor.start { isComplete = true }
    }

    /// Sorts the keys loaded since the last call, leaving every earlier key where it was.
    public mutating func finishLoad() {
        if loadStart < keys.count { keys[loadStart...].sort() }
        loadStart = keys.count
    }

    /// The keys of one page, empty past the end of what the walk loaded.
    public func page(offset: Int, limit: Int) -> [String] {
        let start = min(max(0, offset), keys.count)
        let end = min(start + max(0, limit), keys.count)
        return Array(keys[start..<end])
    }
}
