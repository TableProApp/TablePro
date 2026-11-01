import Foundation

public struct MemcachedKeyEntry: Equatable, Sendable {
    public let key: String
    /// Unix time the item expires at, or nil for an item that never expires.
    public let expiresAt: Int64?
    public let flags: UInt32?

    public init(key: String, expiresAt: Int64?, flags: UInt32?) {
        self.key = key
        self.expiresAt = expiresAt
        self.flags = flags
    }

    /// Seconds left at `serverTime`, nil for no expiry. An item past its time reads as gone.
    public func secondsLeft(at serverTime: Int64) -> Int64? {
        expiresAt.map { $0 - serverTime }
    }

    public func isExpired(at serverTime: Int64) -> Bool {
        (secondsLeft(at: serverTime) ?? 1) <= 0
    }
}

/// How the key list was read. A cachedump is a per-slab sample capped by the server, never the whole cache.
public enum MemcachedKeySource: String, Sendable, Equatable {
    case metadump
    case cachedump
}

public enum MemcachedKeyListing {
    /// One line of `lru_crawler metadump`: `key=a%3A1 exp=-1 la=1793499867 cas=2 fetch=yes cls=1 size=71 flags=5`.
    /// The key is URL-encoded, and `exp` is a Unix time or -1 for never.
    public static func metadumpEntry(_ line: String) -> MemcachedKeyEntry? {
        var fields: [Substring: Substring] = [:]
        for part in line.split(separator: " ") {
            guard let equals = part.firstIndex(of: "=") else { continue }
            fields[part[..<equals]] = part[part.index(after: equals)...]
        }
        guard let encoded = fields["key"], let key = percentDecoded(encoded), !key.isEmpty else { return nil }
        let expiry = fields["exp"].flatMap { Int64($0) }
        return MemcachedKeyEntry(
            key: key,
            expiresAt: expiry.flatMap { $0 > 0 ? $0 : nil },
            flags: fields["flags"].flatMap { UInt32($0) }
        )
    }

    /// One line of `stats cachedump`: `ITEM user:42 [5 b; 1793500167 s]`. An expiry of 0 means never.
    public static func cachedumpEntry(_ line: String) -> MemcachedKeyEntry? {
        guard line.hasPrefix("ITEM "), let open = line.lastIndex(of: "[") else { return nil }
        let key = line[line.index(line.startIndex, offsetBy: 5) ..< open].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        let inside = line[line.index(after: open)...].split(whereSeparator: { $0 == ";" || $0 == " " || $0 == "]" })
        let expiry = inside.count >= 3 ? Int64(inside[2]) : nil
        return MemcachedKeyEntry(key: key, expiresAt: expiry.flatMap { $0 > 0 ? $0 : nil }, flags: nil)
    }

    /// The slab classes holding items, read from `stats items` lines such as `STAT items:1:number 3`.
    public static func slabClasses(fromItemStats lines: [String]) -> [Int] {
        var classes: [Int] = []
        for (name, value) in statPairs(lines) where name.hasSuffix(":number") && (Int(value) ?? 0) > 0 {
            let parts = name.split(separator: ":")
            if parts.count == 3, parts[0] == "items", let id = Int(parts[1]), !classes.contains(id) {
                classes.append(id)
            }
        }
        return classes.sorted()
    }

    /// `STAT <name> <value>` lines as pairs, in the server's order.
    public static func statPairs(_ lines: [String]) -> [(name: String, value: String)] {
        lines.compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0] == "STAT" else { return nil }
            return (String(parts[1]), parts.count == 3 ? String(parts[2]) : "")
        }
    }

    private static func percentDecoded(_ text: Substring) -> String? {
        var bytes: [UInt8] = []
        var iterator = Array(text.utf8)[...]
        while let byte = iterator.popFirst() {
            guard byte == UInt8(ascii: "%") else {
                bytes.append(byte)
                continue
            }
            guard iterator.count >= 2,
                  let decoded = UInt8(String(bytes: iterator.prefix(2), encoding: .ascii) ?? "", radix: 16) else { return nil }
            bytes.append(decoded)
            iterator = iterator.dropFirst(2)
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}
