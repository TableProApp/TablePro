import Foundation

// A command reads only when its verb is on this list, so a verb the list has never heard of counts as a write.
// Checked by name against Redis 8.10.3 `COMMAND DOCS`: a module command flagged readonly can still change state.
public enum RedisReadCommands {
    public static let verbs: Set<String> = [
        "GET", "MGET", "STRLEN", "GETRANGE", "SUBSTR", "LCS", "DIGEST", "EXISTS", "TYPE", "TTL", "PTTL",
        "EXPIRETIME", "PEXPIRETIME", "KEYS", "SCAN", "RANDOMKEY", "DBSIZE", "DUMP",
        "HGET", "HMGET", "HGETALL", "HKEYS", "HVALS", "HLEN", "HEXISTS", "HRANDFIELD",
        "HSCAN", "HSTRLEN", "HTTL", "HPTTL", "HEXPIRETIME", "HPEXPIRETIME", "LRANGE", "LLEN", "LINDEX", "LPOS",
        "SMEMBERS", "SISMEMBER", "SMISMEMBER", "SCARD", "SRANDMEMBER", "SSCAN",
        "SDIFF", "SINTER", "SUNION", "SINTERCARD", "SDIFFCARD", "SUNIONCARD",
        "ZRANGE", "ZRANGEBYSCORE", "ZRANGEBYLEX", "ZREVRANGE", "ZREVRANGEBYSCORE",
        "ZREVRANGEBYLEX", "ZRANK", "ZREVRANK", "ZSCORE", "ZMSCORE", "ZCARD", "ZCOUNT",
        "ZLEXCOUNT", "ZSCAN", "ZRANDMEMBER", "ZDIFF", "ZINTER", "ZUNION", "ZINTERCARD",
        "XRANGE", "XREVRANGE", "XLEN", "XREAD", "XINFO", "XPENDING",
        "PFCOUNT", "BITCOUNT", "BITPOS", "GETBIT", "BITFIELD_RO",
        "GEOPOS", "GEODIST", "GEOHASH", "GEOSEARCH", "GEORADIUS_RO", "GEORADIUSBYMEMBER_RO",
        "SORT_RO", "OBJECT", "COMMAND", "INFO", "TIME", "LASTSAVE", "PING", "ECHO", "LOLWUT",
        "ARCOUNT", "ARGET", "ARGETRANGE", "ARGREP", "ARINFO", "ARLASTITEMS", "ARLEN", "ARMGET", "ARNEXT", "AROP",
        "ARSCAN",
        "JSON.GET", "JSON.MGET", "JSON.TYPE", "JSON.OBJKEYS", "JSON.ARRLEN", "JSON.STRLEN", "JSON.ARRINDEX",
        "JSON.OBJLEN", "JSON.RESP",
        "TS.RANGE", "TS.REVRANGE", "TS.GET", "TS.MGET", "TS.INFO", "TS.MRANGE", "TS.MREVRANGE", "TS.NRANGE",
        "TS.NREVRANGE", "TS.QUERYINDEX", "TS.QUERYLABELS", "TS.READ",
        "FT.SEARCH", "FT.INFO", "FT.AGGREGATE", "FT.HYBRID", "FT.PROFILE", "FT.EXPLAIN", "FT.EXPLAINCLI", "FT.GET",
        "FT.MGET", "FT.SPELLCHECK", "FT.SUGGET", "FT.SUGLEN", "FT.SYNDUMP", "FT.TAGVALS", "FT.DICTDUMP",
        "FT.ALIASLIST",
        "BF.CARD", "BF.EXISTS", "BF.INFO", "BF.MEXISTS", "CF.COUNT", "CF.EXISTS", "CF.INFO", "CF.MEXISTS",
        "CMS.INFO", "CMS.QUERY", "TOPK.COUNT", "TOPK.INFO", "TOPK.LIST", "TOPK.QUERY",
        "TDIGEST.BYRANK", "TDIGEST.BYREVRANK", "TDIGEST.CDF", "TDIGEST.INFO", "TDIGEST.MAX", "TDIGEST.MIN",
        "TDIGEST.QUANTILE", "TDIGEST.RANK", "TDIGEST.REVRANK", "TDIGEST.TRIMMED_MEAN",
        "VCARD", "VDIM", "VEMB", "VGETATTR", "VINFO", "VISMEMBER", "VLINKS", "VRANDMEMBER", "VRANGE", "VSIM"
    ]

    // `CONFIG GET` reads, and every other `CONFIG` subcommand changes the server.
    public static func onlyReads(_ words: ArraySlice<String>) -> Bool {
        guard let verb = words.first?.uppercased() else { return true }
        if verb == "CONFIG" { return words.dropFirst().first?.uppercased() == "GET" }
        return verbs.contains(verb)
    }
}
