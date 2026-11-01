import Foundation

/// The console lines a grid edit becomes. Each one parses back into the command it stands for.
public enum MemcachedStatements {
    /// Memcached reads an exptime above 30 days as a Unix time rather than seconds from now.
    public static let relativeExptimeLimit: Int64 = 60 * 60 * 24 * 30

    /// The text protocol reads an exptime as a 32-bit number.
    public static let maximumExptime = Int64(Int32.max)

    /// No TTL, or 0, keeps the item until it is evicted. A TTL past 30 days is sent as the time it ends. Nil when
    /// the end falls past what the protocol can carry.
    public static func exptime(forTTL ttl: Int64?, now: Int64) -> Int64? {
        guard let ttl, ttl != 0 else { return 0 }
        guard ttl > relativeExptimeLimit else { return ttl >= -maximumExptime ? ttl : nil }
        let (end, overflow) = now.addingReportingOverflow(ttl)
        return !overflow && end <= maximumExptime ? end : nil
    }

    public static func set(key: String, flags: UInt32, exptime: Int64, value: String) -> String {
        "set \(MemcachedCommandParser.argument(key)) \(flags) \(exptime) \(MemcachedCommandParser.quoted(value))"
    }

    public static func set(key: String, flags: UInt32, exptime: Int64, bytes: Data) -> String {
        "set \(MemcachedCommandParser.argument(key)) \(flags) \(exptime) \(MemcachedCommandParser.quoted(bytes: bytes))"
    }

    public static func touch(key: String, exptime: Int64) -> String {
        "touch \(MemcachedCommandParser.argument(key)) \(exptime)"
    }

    public static func delete(key: String) -> String {
        "delete \(MemcachedCommandParser.argument(key))"
    }
}
