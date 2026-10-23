use crate::sql_syntax::StatementAccess;

/// Whether the editor can send a command at all.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EditorUse {
    Sendable,
    /// The command turns the connection into a stream of pushes or stops
    /// its replies, so one reply per command no longer holds. The name
    /// is the command as the app words it.
    Refused(&'static str),
}

/// Commands that only read the keyspace or report on the server. A
/// command missing here counts as a write, so a new one is refused on a
/// read-only connection until it is listed.
const READS: &[&str] = &[
    // Keys.
    "EXISTS",
    "TYPE",
    "TTL",
    "PTTL",
    "EXPIRETIME",
    "PEXPIRETIME",
    "KEYS",
    "SCAN",
    "RANDOMKEY",
    "DBSIZE",
    "DUMP",
    "TOUCH",
    // Strings and bitmaps.
    "GET",
    "MGET",
    "GETRANGE",
    "SUBSTR",
    "STRLEN",
    "GETBIT",
    "BITCOUNT",
    "BITPOS",
    "BITFIELD_RO",
    "LCS",
    // Hashes.
    "HGET",
    "HMGET",
    "HGETALL",
    "HKEYS",
    "HVALS",
    "HLEN",
    "HEXISTS",
    "HSTRLEN",
    "HSCAN",
    "HRANDFIELD",
    "HTTL",
    "HPTTL",
    "HEXPIRETIME",
    "HPEXPIRETIME",
    // Lists.
    "LRANGE",
    "LINDEX",
    "LLEN",
    "LPOS",
    // Sets.
    "SMEMBERS",
    "SISMEMBER",
    "SMISMEMBER",
    "SCARD",
    "SSCAN",
    "SRANDMEMBER",
    "SINTER",
    "SUNION",
    "SDIFF",
    "SINTERCARD",
    // Sorted sets.
    "ZRANGE",
    "ZRANGEBYSCORE",
    "ZREVRANGE",
    "ZREVRANGEBYSCORE",
    "ZRANGEBYLEX",
    "ZREVRANGEBYLEX",
    "ZCARD",
    "ZCOUNT",
    "ZLEXCOUNT",
    "ZSCORE",
    "ZMSCORE",
    "ZRANK",
    "ZREVRANK",
    "ZSCAN",
    "ZRANDMEMBER",
    "ZINTER",
    "ZUNION",
    "ZDIFF",
    "ZINTERCARD",
    // Streams.
    "XRANGE",
    "XREVRANGE",
    "XLEN",
    "XREAD",
    "XINFO",
    "XPENDING",
    // HyperLogLog and geo.
    "PFCOUNT",
    "GEOPOS",
    "GEODIST",
    "GEOHASH",
    "GEOSEARCH",
    "GEORADIUS_RO",
    "GEORADIUSBYMEMBER_RO",
    // Read-only forms of commands that can write.
    "SORT_RO",
    "EVAL_RO",
    "EVALSHA_RO",
    "FCALL_RO",
    // The connection's own state, which changes no data.
    "PING",
    "ECHO",
    "SELECT",
    "AUTH",
    "RESET",
    "MULTI",
    "EXEC",
    "DISCARD",
    "WATCH",
    "UNWATCH",
    "READONLY",
    "READWRITE",
    "ASKING",
    "WAIT",
    "WAITAOF",
    // Reports on the server.
    "TIME",
    "INFO",
    "LASTSAVE",
    "ROLE",
    "LOLWUT",
    "COMMAND",
    // Modules most servers carry.
    "JSON.GET",
    "JSON.MGET",
    "JSON.TYPE",
    "JSON.STRLEN",
    "JSON.ARRLEN",
    "JSON.ARRINDEX",
    "JSON.OBJKEYS",
    "JSON.OBJLEN",
    "JSON.RESP",
    "FT.SEARCH",
    "FT.AGGREGATE",
    "FT.INFO",
    "FT._LIST",
    "FT.EXPLAIN",
    "FT.TAGVALS",
    "TS.GET",
    "TS.MGET",
    "TS.RANGE",
    "TS.REVRANGE",
    "TS.MRANGE",
    "TS.MREVRANGE",
    "TS.INFO",
    "TS.QUERYINDEX",
    "BF.EXISTS",
    "BF.MEXISTS",
    "BF.INFO",
    "CF.EXISTS",
    "CF.MEXISTS",
    "CF.COUNT",
    "CF.INFO",
];

/// Containers whose subcommand decides, and the subcommands that only
/// read.
const READ_SUBCOMMANDS: &[(&str, &[&str])] = &[
    ("OBJECT", &["ENCODING", "FREQ", "IDLETIME", "REFCOUNT", "HELP"]),
    ("CONFIG", &["GET", "HELP"]),
    (
        "CLIENT",
        &[
            "LIST",
            "INFO",
            "GETNAME",
            "ID",
            "GETREDIR",
            "TRACKINGINFO",
            "HELP",
            "SETNAME",
            "SETINFO",
            "NO-EVICT",
            "NO-TOUCH",
            "CACHING",
        ],
    ),
    ("MEMORY", &["USAGE", "STATS", "DOCTOR", "MALLOC-STATS", "HELP"]),
    ("SLOWLOG", &["GET", "LEN", "HELP"]),
    (
        "LATENCY",
        &["LATEST", "HISTORY", "DOCTOR", "GRAPH", "HISTOGRAM", "HELP"],
    ),
    (
        "ACL",
        &["WHOAMI", "LIST", "USERS", "GETUSER", "CAT", "DRYRUN", "GENPASS", "HELP"],
    ),
    ("MODULE", &["LIST", "HELP"]),
    ("FUNCTION", &["LIST", "DUMP", "STATS", "HELP"]),
    ("SCRIPT", &["EXISTS", "HELP"]),
    (
        "PUBSUB",
        &["CHANNELS", "NUMSUB", "NUMPAT", "SHARDCHANNELS", "SHARDNUMSUB", "HELP"],
    ),
    (
        "CLUSTER",
        &[
            "INFO",
            "NODES",
            "SLOTS",
            "SHARDS",
            "MYID",
            "MYSHARDID",
            "COUNTKEYSINSLOT",
            "GETKEYSINSLOT",
            "KEYSLOT",
            "LINKS",
            "REPLICAS",
            "SLAVES",
            "COUNT-FAILURE-REPORTS",
            "HELP",
        ],
    ),
];

/// Commands whose damage cannot be undone by another command: they
/// empty databases, stop the server or lose code.
const DESTRUCTIVE: &[&str] = &["FLUSHALL", "FLUSHDB", "SWAPDB", "SHUTDOWN", "DEBUG"];

const DESTRUCTIVE_SUBCOMMANDS: &[(&str, &str)] = &[("FUNCTION", "FLUSH")];

/// What running one command can do. `arguments` starts with the command
/// name.
pub fn command_access(arguments: &[Vec<u8>]) -> StatementAccess {
    let Some(name) = arguments.first().map(|name| upper(name)) else {
        return StatementAccess::Read;
    };
    let sub = arguments.get(1).map(|sub| upper(sub));
    let sub = sub.as_deref().unwrap_or_default();
    if DESTRUCTIVE.contains(&name.as_str())
        || DESTRUCTIVE_SUBCOMMANDS
            .iter()
            .any(|(container, subcommand)| *container == name && *subcommand == sub)
    {
        return StatementAccess::Destructive;
    }
    let reads = match name.as_str() {
        "SORT" => !stores_result(arguments, 2, sort_operands),
        "GEORADIUS" => !stores_result(arguments, 6, georadius_operands),
        "GEORADIUSBYMEMBER" => !stores_result(arguments, 5, georadius_operands),
        "ACL" if sub == "LOG" => !arguments.get(2).is_some_and(|word| word.eq_ignore_ascii_case(b"RESET")),
        _ => {
            READS.contains(&name.as_str())
                || READ_SUBCOMMANDS
                    .iter()
                    .any(|(container, subs)| *container == name && subs.contains(&sub))
        }
    };
    if reads {
        StatementAccess::Read
    } else {
        StatementAccess::Write
    }
}

/// Whether the editor can run the command and read one reply for it.
pub fn editor_use(arguments: &[Vec<u8>]) -> EditorUse {
    let Some(name) = arguments.first().map(|name| upper(name)) else {
        return EditorUse::Sendable;
    };
    let sub = arguments.get(1).map(|sub| upper(sub));
    match (name.as_str(), sub.as_deref()) {
        ("SUBSCRIBE", _) => EditorUse::Refused("SUBSCRIBE"),
        ("PSUBSCRIBE", _) => EditorUse::Refused("PSUBSCRIBE"),
        ("SSUBSCRIBE", _) => EditorUse::Refused("SSUBSCRIBE"),
        ("UNSUBSCRIBE", _) => EditorUse::Refused("UNSUBSCRIBE"),
        ("PUNSUBSCRIBE", _) => EditorUse::Refused("PUNSUBSCRIBE"),
        ("SUNSUBSCRIBE", _) => EditorUse::Refused("SUNSUBSCRIBE"),
        ("MONITOR", _) => EditorUse::Refused("MONITOR"),
        ("SYNC", _) => EditorUse::Refused("SYNC"),
        ("PSYNC", _) => EditorUse::Refused("PSYNC"),
        ("REPLCONF", _) => EditorUse::Refused("REPLCONF"),
        ("QUIT", _) => EditorUse::Refused("QUIT"),
        ("CLIENT", Some("REPLY")) => EditorUse::Refused("CLIENT REPLY"),
        // The Lua debugger answers a script with a session of its own.
        ("SCRIPT", Some("DEBUG")) if arguments.get(2).is_some_and(|mode| !mode.eq_ignore_ascii_case(b"NO")) => {
            EditorUse::Refused("SCRIPT DEBUG")
        }
        // RESP3 changes the shape of every reply after it.
        ("HELLO", Some(protocol)) if protocol != "2" => EditorUse::Refused("HELLO"),
        _ => EditorUse::Sendable,
    }
}

/// Whether the options from `first` on store the result, read option by
/// option as the server reads them, so a key or an operand spelt `store`
/// is not taken for the option. An option the server does not know makes
/// it refuse the command, and is taken as a write all the same.
fn stores_result(arguments: &[Vec<u8>], first: usize, operands: fn(&str) -> Option<usize>) -> bool {
    let mut index = first;
    while let Some(option) = arguments.get(index) {
        let option = upper(option);
        if matches!(option.as_str(), "STORE" | "STOREDIST") {
            return true;
        }
        let Some(count) = operands(&option) else {
            return true;
        };
        index += 1 + count;
    }
    false
}

fn sort_operands(option: &str) -> Option<usize> {
    match option {
        "ASC" | "DESC" | "ALPHA" => Some(0),
        "BY" | "GET" => Some(1),
        "LIMIT" => Some(2),
        _ => None,
    }
}

fn georadius_operands(option: &str) -> Option<usize> {
    match option {
        "WITHCOORD" | "WITHDIST" | "WITHHASH" | "ANY" | "ASC" | "DESC" => Some(0),
        "COUNT" => Some(1),
        _ => None,
    }
}

fn upper(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).to_ascii_uppercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn argv(text: &str) -> Vec<Vec<u8>> {
        text.split_whitespace().map(|part| part.as_bytes().to_vec()).collect()
    }

    fn access(text: &str) -> StatementAccess {
        command_access(&argv(text))
    }

    #[test]
    fn reads_are_reads_in_any_case() {
        for command in [
            "GET k",
            "get k",
            "HSCAN h 0",
            "ZRANGE z 0 -1 WITHSCORES",
            "XRANGE s - +",
            "INFO",
        ] {
            assert_eq!(access(command), StatementAccess::Read, "{command}");
        }
    }

    #[test]
    fn a_command_not_listed_is_a_write() {
        for command in [
            "SET k v",
            "DEL k",
            "HSET h f v",
            "EXPIRE k 10",
            "EVAL x 0",
            "FROBNICATE",
        ] {
            assert_eq!(access(command), StatementAccess::Write, "{command}");
        }
    }

    #[test]
    fn the_subcommand_decides_for_a_container() {
        assert_eq!(access("CONFIG GET maxmemory"), StatementAccess::Read);
        assert_eq!(access("CONFIG SET maxmemory 1"), StatementAccess::Write);
        assert_eq!(access("CLIENT LIST"), StatementAccess::Read);
        assert_eq!(access("CLIENT KILL ID 7"), StatementAccess::Write);
        assert_eq!(access("ACL LOG"), StatementAccess::Read);
        assert_eq!(access("ACL LOG RESET"), StatementAccess::Write);
        assert_eq!(access("ACL SETUSER u on"), StatementAccess::Write);
    }

    #[test]
    fn a_store_option_makes_a_read_command_write() {
        assert_eq!(access("SORT list"), StatementAccess::Read);
        assert_eq!(access("SORT list STORE out"), StatementAccess::Write);
        assert_eq!(
            access("sort list by w_* limit 0 10 get # alpha store out"),
            StatementAccess::Write
        );
        assert_eq!(access("GEORADIUS g 0 0 1 km STOREDIST out"), StatementAccess::Write);
        assert_eq!(
            access("GEORADIUSBYMEMBER g m 1 km COUNT 5 STORE out"),
            StatementAccess::Write
        );
        assert_eq!(access("SORT list NOSUCHOPTION"), StatementAccess::Write);
    }

    #[test]
    fn store_as_a_key_or_an_operand_is_not_the_option() {
        for command in [
            "SORT store",
            "SORT list BY store",
            "SORT list GET store LIMIT 0 10 DESC",
            "GEORADIUS store 0 0 1 km",
            "GEORADIUSBYMEMBER g storedist 1 km WITHDIST COUNT 3 ASC",
            "ACL LOG 10",
        ] {
            assert_eq!(access(command), StatementAccess::Read, "{command}");
        }
    }

    #[test]
    fn emptying_a_database_is_destructive() {
        for command in [
            "FLUSHDB",
            "flushall ASYNC",
            "SWAPDB 0 1",
            "SHUTDOWN NOSAVE",
            "FUNCTION FLUSH",
        ] {
            assert_eq!(access(command), StatementAccess::Destructive, "{command}");
        }
    }

    #[test]
    fn push_and_replication_commands_cannot_run_in_the_editor() {
        assert_eq!(editor_use(&argv("subscribe news")), EditorUse::Refused("SUBSCRIBE"));
        assert_eq!(editor_use(&argv("MONITOR")), EditorUse::Refused("MONITOR"));
        assert_eq!(
            editor_use(&argv("CLIENT REPLY OFF")),
            EditorUse::Refused("CLIENT REPLY")
        );
        assert_eq!(editor_use(&argv("HELLO 3")), EditorUse::Refused("HELLO"));
        assert_eq!(
            editor_use(&argv("SCRIPT DEBUG YES")),
            EditorUse::Refused("SCRIPT DEBUG")
        );
        assert_eq!(
            editor_use(&argv("script debug sync")),
            EditorUse::Refused("SCRIPT DEBUG")
        );
        assert_eq!(editor_use(&argv("SCRIPT DEBUG NO")), EditorUse::Sendable);
        assert_eq!(editor_use(&argv("HELLO 2")), EditorUse::Sendable);
        assert_eq!(editor_use(&argv("GET k")), EditorUse::Sendable);
    }
}
