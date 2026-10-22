import Foundation
import TableProModels

// Each engine's own reserved words, from its reference. `SQLKeywords` is a completion vocabulary and misses some,
// such as PostgreSQL's `user`, which a bare name would then read as.
nonisolated enum CompletionReservedWords {
    static func contains(_ name: String, for type: DatabaseType) -> Bool {
        words(for: type).contains(name.lowercased())
    }

    private static func words(for type: DatabaseType) -> Set<String> {
        if SQLBuilder.speaksMySQLDialect(type) { return mySQL }
        switch type {
        case .postgresql, .redshift: return postgreSQL
        case .duckdb: return duckDB
        case .mssql: return sqlServer
        case .oracle: return oracle
        case .sqlite: return sqlite
        default: return all
        }
    }

    private static let postgreSQL: Set<String> = [
        "all", "analyse", "analyze", "and", "any", "array", "as", "asc", "asymmetric", "both", "case", "cast", "check",
        "collate", "column", "constraint", "create", "current_catalog", "current_date", "current_role", "current_time",
        "current_timestamp", "current_user", "default", "deferrable", "desc", "distinct", "do", "else", "end", "except",
        "false", "fetch", "for", "foreign", "from", "grant", "group", "having", "in", "initially", "intersect", "into",
        "lateral", "leading", "limit", "localtime", "localtimestamp", "not", "null", "offset", "on", "only", "or",
        "order", "placing", "primary", "references", "returning", "select", "session_user", "some", "symmetric",
        "system_user", "table", "then", "to", "trailing", "true", "union", "unique", "user", "using", "variadic", "when",
        "where", "window", "with", "authorization", "binary", "collation", "concurrently", "cross", "current_schema",
        "freeze", "full", "ilike", "inner", "is", "isnull", "join", "left", "like", "natural", "notnull", "outer",
        "overlaps", "right", "similar", "tablesample", "verbose",
    ]

    private static let duckDB: Set<String> = postgreSQL.union([
        "describe", "pivot", "pivot_longer", "pivot_wider", "qualify", "show", "summarize", "unpivot",
    ])

    private static let mySQL: Set<String> = [
        "accessible", "add", "all", "alter", "analyze", "and", "as", "asc", "asensitive", "before", "between", "bigint",
        "binary", "blob", "both", "by", "call", "cascade", "case", "change", "char", "character", "check", "collate",
        "column", "condition", "constraint", "continue", "convert", "create", "cross", "cube", "cume_dist",
        "current_date", "current_role", "current_time", "current_timestamp", "current_user", "cursor", "database",
        "databases", "day_hour", "day_microsecond", "day_minute", "day_second", "dec", "decimal", "declare", "default",
        "delayed", "delete", "dense_rank", "desc", "describe", "deterministic", "distinct", "distinctrow", "div",
        "double", "drop", "dual", "each", "else", "elseif", "empty", "enclosed", "escaped", "except", "exists", "exit",
        "explain", "false", "fetch", "first_value", "float", "float4", "float8", "for", "force", "foreign", "from",
        "fulltext", "function", "general", "generated", "get", "grant", "group", "grouping", "groups", "having",
        "high_priority", "hour_microsecond", "hour_minute", "hour_second", "if", "ignore", "in", "index", "infile",
        "inner", "inout", "insensitive", "insert", "int", "int1", "int2", "int3", "int4", "int8", "integer",
        "intersect", "interval", "into", "io_after_gtids", "io_before_gtids", "is", "iterate", "join", "json_table",
        "key", "keys", "kill", "lag", "last_value", "lateral", "lead", "leading", "leave", "left", "like", "limit",
        "linear", "lines", "load", "localtime", "localtimestamp", "lock", "long", "longblob", "longtext", "loop",
        "low_priority", "manual", "master_bind", "master_ssl_verify_server_cert", "match", "maxvalue", "mediumblob",
        "mediumint", "mediumtext", "middleint", "minute_microsecond", "minute_second", "mod", "modifies", "natural",
        "not", "no_write_to_binlog", "nth_value", "ntile", "null", "numeric", "of", "offset", "on", "optimize",
        "optimizer_costs", "option", "optionally", "or", "order", "out", "outer", "outfile", "over", "parallel",
        "partition", "percent_rank", "precision", "primary", "procedure", "purge", "qualify", "range", "rank", "read",
        "reads", "read_write", "real", "recursive", "references", "regexp", "release", "rename", "repeat", "replace",
        "require", "resignal", "restrict", "return", "returning", "revoke", "right", "rlike", "row", "rows",
        "row_number", "schema", "schemas", "second_microsecond", "select", "sensitive", "separator", "set", "show",
        "signal", "slow", "smallint", "spatial", "specific", "sql", "sqlexception", "sqlstate", "sqlwarning",
        "sql_big_result", "sql_calc_found_rows", "sql_small_result", "ssl", "starting", "stored", "straight_join",
        "system", "table", "terminated", "then", "tinyblob", "tinyint", "tinytext", "to", "trailing", "trigger", "true",
        "undo", "union", "unique", "unlock", "unsigned", "update", "usage", "use", "using", "utc_date", "utc_time",
        "utc_timestamp", "values", "varbinary", "varchar", "varcharacter", "varying", "virtual", "when", "where",
        "while", "window", "with", "write", "xor", "year_month", "zerofill",
    ]

    private static let sqlServer: Set<String> = [
        "add", "all", "alter", "and", "any", "as", "asc", "authorization", "backup", "begin", "between", "break",
        "browse", "bulk", "by", "cascade", "case", "check", "checkpoint", "close", "clustered", "coalesce", "collate",
        "column", "commit", "compute", "constraint", "contains", "containstable", "continue", "convert", "create",
        "cross", "current", "current_date", "current_time", "current_timestamp", "current_user", "cursor", "database",
        "dbcc", "deallocate", "declare", "default", "delete", "deny", "desc", "disk", "distinct", "distributed",
        "double", "drop", "dump", "else", "end", "errlvl", "escape", "except", "exec", "execute", "exists", "exit",
        "external", "fetch", "file", "fillfactor", "for", "foreign", "freetext", "freetexttable", "from", "full",
        "function", "goto", "grant", "group", "having", "holdlock", "identity", "identity_insert", "identitycol", "if",
        "in", "index", "inner", "insert", "intersect", "into", "is", "join", "key", "kill", "left", "like", "lineno",
        "load", "merge", "national", "nocheck", "nonclustered", "not", "null", "nullif", "of", "off", "offsets", "on",
        "open", "opendatasource", "openquery", "openrowset", "openxml", "option", "or", "order", "outer", "over",
        "percent", "pivot", "plan", "precision", "primary", "print", "proc", "procedure", "public", "raiserror", "read",
        "readtext", "reconfigure", "references", "replication", "restore", "restrict", "return", "revert", "revoke",
        "right", "rollback", "rowcount", "rowguidcol", "rule", "save", "schema", "securityaudit", "select",
        "semantickeyphrasetable", "semanticsimilaritydetailstable", "semanticsimilaritytable", "session_user", "set",
        "setuser", "shutdown", "some", "statistics", "system_user", "table", "tablesample", "textsize", "then", "to",
        "top", "tran", "transaction", "trigger", "truncate", "try_convert", "tsequal", "union", "unique", "unpivot",
        "update", "updatetext", "use", "user", "values", "varying", "view", "waitfor", "when", "where", "while", "with",
        "writetext",
    ]

    private static let oracle: Set<String> = [
        "access", "add", "all", "alter", "and", "any", "as", "asc", "audit", "between", "by", "char", "check",
        "cluster", "column", "comment", "compress", "connect", "create", "current", "date", "decimal", "default",
        "delete", "desc", "distinct", "drop", "else", "exclusive", "exists", "file", "float", "for", "from", "grant",
        "group", "having", "identified", "immediate", "in", "increment", "index", "initial", "insert", "integer",
        "intersect", "into", "is", "level", "like", "lock", "long", "maxextents", "minus", "mlslabel", "mode",
        "modify", "noaudit", "nocompress", "not", "nowait", "null", "number", "of", "offline", "on", "online", "option",
        "or", "order", "pctfree", "prior", "public", "raw", "rename", "resource", "revoke", "row", "rowid", "rownum",
        "rows", "select", "session", "set", "share", "size", "smallint", "start", "successful", "synonym", "sysdate",
        "table", "then", "to", "trigger", "uid", "union", "unique", "update", "user", "validate", "values", "varchar",
        "varchar2", "view", "whenever", "where", "with",
    ]

    private static let sqlite: Set<String> = [
        "abort", "action", "add", "after", "all", "alter", "always", "analyze", "and", "as", "asc", "attach",
        "autoincrement", "before", "begin", "between", "by", "cascade", "case", "cast", "check", "collate", "column",
        "commit", "conflict", "constraint", "create", "cross", "current", "current_date", "current_time",
        "current_timestamp", "database", "default", "deferrable", "deferred", "delete", "desc", "detach", "distinct",
        "do", "drop", "each", "else", "end", "escape", "except", "exclude", "exclusive", "exists", "explain", "fail",
        "filter", "first", "following", "for", "foreign", "from", "full", "generated", "glob", "group", "groups",
        "having", "if", "ignore", "immediate", "in", "index", "indexed", "initially", "inner", "insert", "instead",
        "intersect", "into", "is", "isnull", "join", "key", "last", "left", "like", "limit", "match", "materialized",
        "natural", "no", "not", "nothing", "notnull", "null", "nulls", "of", "offset", "on", "or", "order", "others",
        "outer", "over", "partition", "plan", "pragma", "preceding", "primary", "query", "raise", "range", "recursive",
        "references", "regexp", "reindex", "release", "rename", "replace", "restrict", "returning", "right",
        "rollback", "row", "rows", "savepoint", "select", "set", "table", "temp", "temporary", "then", "ties", "to",
        "transaction", "trigger", "unbounded", "union", "unique", "update", "using", "vacuum", "values", "view",
        "virtual", "when", "where", "window", "with", "without",
    ]

    private static let all: Set<String> = postgreSQL.union(duckDB).union(mySQL).union(sqlServer).union(oracle)
        .union(sqlite)
}
