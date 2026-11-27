//
//  PluginMetadataRegistry+CommandEngineDataCommands.swift
//  TablePro
//

import Foundation

extension PluginMetadataRegistry {
    // Redis 8.10.3 `COMMAND DOCS` with its modules (search, timeseries, bf, vectorset, ReJSON). A container command is
    // named `CONTAINER|SUB`. Keys only: no index, alias, rule, user, function, session or server state.
    static let redisDataCommands: Set<String> = [
        "APPEND", "DECR", "DECRBY", "DELEX", "GETDEL", "GETEX", "GETSET", "INCR", "INCRBY", "INCRBYFLOAT", "INCREX",
        "MSET", "MSETEX", "MSETNX", "PSETEX", "SET", "SETEX", "SETNX", "SETRANGE",
        "COPY", "DEL", "EXPIRE", "EXPIREAT", "MOVE", "PERSIST", "PEXPIRE", "PEXPIREAT", "RENAME", "RENAMENX",
        "RESTORE", "SORT", "UNLINK",
        "HDEL", "HEXPIRE", "HEXPIREAT", "HGETDEL", "HGETEX", "HINCRBY", "HINCRBYFLOAT", "HMSET", "HPERSIST",
        "HPEXPIRE", "HPEXPIREAT", "HSET", "HSETEX", "HSETNX",
        "LINSERT", "LMOVE", "LMOVEM", "LMPOP", "LPOP", "LPUSH", "LPUSHX", "LREM", "LSET", "LTRIM", "RPOP",
        "RPOPLPUSH", "RPUSH", "RPUSHX", "BLMOVE", "BLMOVEM", "BLMPOP", "BLPOP", "BRPOP", "BRPOPLPUSH",
        "SADD", "SDIFFSTORE", "SINTERSTORE", "SMOVE", "SPOP", "SREM", "SUNIONSTORE",
        "ZADD", "ZDIFFSTORE", "ZINCRBY", "ZINTERSTORE", "ZMPOP", "ZPOPMAX", "ZPOPMIN", "ZRANGESTORE", "ZREM",
        "ZREMRANGEBYLEX", "ZREMRANGEBYRANK", "ZREMRANGEBYSCORE", "ZUNIONSTORE", "BZMPOP", "BZPOPMAX", "BZPOPMIN",
        "XACK", "XACKDEL", "XADD", "XAUTOCLAIM", "XCFGSET", "XCLAIM", "XDEL", "XDELEX", "XGROUP|CREATE",
        "XGROUP|CREATECONSUMER", "XGROUP|DELCONSUMER", "XGROUP|DESTROY", "XGROUP|SETID", "XNACK", "XREADGROUP",
        "XSETID", "XTRIM",
        "BITFIELD", "BITOP", "SETBIT", "GEOADD", "GEORADIUS", "GEORADIUSBYMEMBER", "GEOSEARCHSTORE", "PFADD",
        "PFMERGE",
        "ARDEL", "ARDELRANGE", "ARINSERT", "ARMSET", "ARRING", "ARSEEK", "ARSET",
        "JSON.ARRAPPEND", "JSON.ARRINSERT", "JSON.ARRPOP", "JSON.ARRTRIM", "JSON.CLEAR", "JSON.DEL", "JSON.FORGET",
        "JSON.MERGE", "JSON.MSET", "JSON.NUMINCRBY", "JSON.NUMMULTBY", "JSON.NUMPOWBY", "JSON.SET", "JSON.STRAPPEND",
        "JSON.TOGGLE",
        "TS.ADD", "TS.ALTER", "TS.CREATE", "TS.DECRBY", "TS.DEL", "TS.INCRBY", "TS.MADD",
        "FT.ADD", "FT.SAFEADD", "FT.DEL", "FT.SUGADD", "FT.SUGDEL",
        "BF.ADD", "BF.INSERT", "BF.LOADCHUNK", "BF.MADD", "BF.RESERVE", "CF.ADD", "CF.ADDNX", "CF.COMPACT", "CF.DEL",
        "CF.INSERT", "CF.INSERTNX", "CF.LOADCHUNK", "CF.RESERVE", "CMS.INCRBY", "CMS.INITBYDIM", "CMS.INITBYPROB",
        "CMS.MERGE", "TDIGEST.ADD", "TDIGEST.CREATE", "TDIGEST.MERGE", "TDIGEST.RESET", "TOPK.ADD", "TOPK.INCRBY",
        "TOPK.RESERVE",
        "VADD", "VREM", "VSETATTR",
    ]

    // etcd v3.6 API reference, in the driver's etcdctl notation. `create` and `mv` are the driver's own KV verbs.
    static let etcdDataCommands: Set<String> = [
        "put", "create", "mv", "del", "lease grant", "lease keep-alive",
    ]
}
