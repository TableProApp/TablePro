import Foundation

// A command reads only when its verb is on this list, so a verb the list has never heard of counts as a write.
public enum RedisReadCommands {
    public static let verbs: Set<String> = [
        "GET", "MGET", "STRLEN", "GETRANGE", "SUBSTR", "EXISTS", "TYPE", "TTL", "PTTL",
        "EXPIRETIME", "PEXPIRETIME", "KEYS", "SCAN", "RANDOMKEY", "DBSIZE", "DUMP",
        "HGET", "HMGET", "HGETALL", "HKEYS", "HVALS", "HLEN", "HEXISTS", "HRANDFIELD",
        "HSCAN", "HSTRLEN", "LRANGE", "LLEN", "LINDEX", "LPOS",
        "SMEMBERS", "SISMEMBER", "SMISMEMBER", "SCARD", "SRANDMEMBER", "SSCAN",
        "SDIFF", "SINTER", "SUNION", "SINTERCARD",
        "ZRANGE", "ZRANGEBYSCORE", "ZRANGEBYLEX", "ZREVRANGE", "ZREVRANGEBYSCORE",
        "ZREVRANGEBYLEX", "ZRANK", "ZREVRANK", "ZSCORE", "ZMSCORE", "ZCARD", "ZCOUNT",
        "ZLEXCOUNT", "ZSCAN", "ZRANDMEMBER", "ZDIFF", "ZINTER", "ZUNION", "ZINTERCARD",
        "XRANGE", "XREVRANGE", "XLEN", "XREAD", "XINFO", "XPENDING",
        "PFCOUNT", "BITCOUNT", "BITPOS", "GETBIT", "BITFIELD_RO",
        "GEOPOS", "GEODIST", "GEOHASH", "GEOSEARCH", "GEORADIUS_RO", "GEORADIUSBYMEMBER_RO",
        "SORT_RO", "OBJECT", "COMMAND", "INFO", "TIME", "LASTSAVE", "PING", "ECHO", "LOLWUT",
        "JSON.GET", "JSON.MGET", "JSON.TYPE", "JSON.OBJKEYS", "JSON.ARRLEN", "JSON.STRLEN",
        "TS.RANGE", "TS.REVRANGE", "TS.GET", "TS.MGET", "TS.INFO", "FT.SEARCH", "FT.INFO"
    ]

    // `CONFIG GET` reads, and every other `CONFIG` subcommand changes the server.
    public static func onlyReads(_ words: ArraySlice<String>) -> Bool {
        guard let verb = words.first?.uppercased() else { return true }
        if verb == "CONFIG" { return words.dropFirst().first?.uppercased() == "GET" }
        return verbs.contains(verb)
    }
}
