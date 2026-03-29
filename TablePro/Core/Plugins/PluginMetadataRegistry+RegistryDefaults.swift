//
//  PluginMetadataRegistry+RegistryDefaults.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PluginMetadataRegistry {
    // swiftlint:disable function_body_length
    func registryPluginDefaults() -> [(typeId: String, snapshot: PluginMetadataSnapshot)] {
        let clickhouseDialect = SQLDialectDescriptor(
            identifierQuote: "`",
            keywords: [
                "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "CROSS", "FULL",
                "ON", "USING", "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN", "AS",
                "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET",
                "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
                "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "DATABASE", "SCHEMA",
                "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CONSTRAINT",
                "ADD", "MODIFY", "COLUMN", "RENAME",
                "NULL", "IS", "ASC", "DESC", "DISTINCT", "ALL", "ANY", "SOME",
                "CASE", "WHEN", "THEN", "ELSE", "END", "COALESCE",
                "UNION", "INTERSECT", "EXCEPT",
                "FINAL", "SAMPLE", "PREWHERE", "GLOBAL", "FORMAT", "SETTINGS",
                "OPTIMIZE", "SYSTEM", "PARTITION", "TTL", "ENGINE", "CODEC",
                "MATERIALIZED", "WITH"
            ],
            functions: [
                "COUNT", "SUM", "AVG", "MAX", "MIN",
                "CONCAT", "SUBSTRING", "LEFT", "RIGHT", "LENGTH", "LOWER", "UPPER",
                "TRIM", "LTRIM", "RTRIM", "REPLACE",
                "NOW", "TODAY", "YESTERDAY",
                "CAST",
                "UNIQ", "UNIQEXACT", "ARGMIN", "ARGMAX", "GROUPARRAY",
                "TOSTRING", "TOINT32", "FORMATDATETIME",
                "IF", "MULTIIF",
                "ARRAYMAP", "ARRAYJOIN",
                "MATCH", "CURRENTDATABASE", "VERSION",
                "QUANTILE", "TOPK"
            ],
            dataTypes: [
                "INT8", "INT16", "INT32", "INT64", "INT128", "INT256",
                "UINT8", "UINT16", "UINT32", "UINT64", "UINT128", "UINT256",
                "FLOAT32", "FLOAT64",
                "DECIMAL", "DECIMAL32", "DECIMAL64", "DECIMAL128", "DECIMAL256",
                "STRING", "FIXEDSTRING", "UUID",
                "DATE", "DATE32", "DATETIME", "DATETIME64",
                "ARRAY", "TUPLE", "MAP",
                "NULLABLE", "LOWCARDINALITY",
                "ENUM8", "ENUM16",
                "IPV4", "IPV6",
                "JSON", "BOOL"
            ],
            tableOptions: [
                "ENGINE=MergeTree()", "ORDER BY", "PARTITION BY", "SETTINGS"
            ],
            regexSyntax: .match,
            booleanLiteralStyle: .numeric,
            likeEscapeStyle: .implicit,
            paginationStyle: .limit,
            requiresBackslashEscaping: true
        )

        let clickhouseColumnTypes: [String: [String]] = [
            "Integer": [
                "UInt8", "UInt16", "UInt32", "UInt64", "UInt128", "UInt256",
                "Int8", "Int16", "Int32", "Int64", "Int128", "Int256"
            ],
            "Float": ["Float32", "Float64", "Decimal", "Decimal32", "Decimal64", "Decimal128", "Decimal256"],
            "String": ["String", "FixedString", "Enum8", "Enum16"],
            "Date": ["Date", "Date32", "DateTime", "DateTime64"],
            "Binary": [],
            "Boolean": ["Bool"],
            "JSON": ["JSON"],
            "UUID": ["UUID"],
            "Array": ["Array"],
            "Map": ["Map"],
            "Tuple": ["Tuple"],
            "IP": ["IPv4", "IPv6"],
            "Geo": ["Point", "Ring", "Polygon", "MultiPolygon"]
        ]

        let mssqlDialect = SQLDialectDescriptor(
            identifierQuote: "[",
            keywords: [
                "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "CROSS", "FULL",
                "ON", "USING", "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN", "AS",
                "ORDER", "BY", "GROUP", "HAVING", "TOP", "OFFSET", "FETCH", "NEXT", "ROWS", "ONLY",
                "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
                "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "DATABASE", "SCHEMA",
                "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CONSTRAINT",
                "ADD", "COLUMN", "RENAME", "EXEC",
                "NULL", "IS", "ASC", "DESC", "DISTINCT", "ALL", "ANY", "SOME",
                "IDENTITY", "NOLOCK", "WITH", "ROWCOUNT", "NEWID",
                "CASE", "WHEN", "THEN", "ELSE", "END", "COALESCE", "NULLIF", "IIF",
                "UNION", "INTERSECT", "EXCEPT",
                "DECLARE", "BEGIN", "COMMIT", "ROLLBACK", "TRANSACTION",
                "PRINT", "GO", "EXECUTE",
                "OVER", "PARTITION", "ROW_NUMBER", "RANK", "DENSE_RANK",
                "RETURNING", "OUTPUT", "INSERTED", "DELETED"
            ],
            functions: [
                "COUNT", "SUM", "AVG", "MAX", "MIN", "STRING_AGG",
                "CONCAT", "SUBSTRING", "LEFT", "RIGHT", "LEN", "LOWER", "UPPER",
                "TRIM", "LTRIM", "RTRIM", "REPLACE", "CHARINDEX", "PATINDEX",
                "STUFF", "FORMAT",
                "GETDATE", "GETUTCDATE", "SYSDATETIME", "CURRENT_TIMESTAMP",
                "DATEADD", "DATEDIFF", "DATENAME", "DATEPART",
                "CONVERT", "CAST",
                "ROUND", "CEILING", "FLOOR", "ABS", "POWER", "SQRT", "RAND",
                "ISNULL", "ISNUMERIC", "ISDATE", "COALESCE", "NEWID",
                "OBJECT_ID", "OBJECT_NAME", "SCHEMA_NAME", "DB_NAME",
                "SCOPE_IDENTITY", "@@IDENTITY", "@@ROWCOUNT"
            ],
            dataTypes: [
                "INT", "INTEGER", "TINYINT", "SMALLINT", "BIGINT",
                "DECIMAL", "NUMERIC", "FLOAT", "REAL", "MONEY", "SMALLMONEY",
                "CHAR", "VARCHAR", "NCHAR", "NVARCHAR", "TEXT", "NTEXT",
                "BINARY", "VARBINARY", "IMAGE",
                "DATE", "TIME", "DATETIME", "DATETIME2", "SMALLDATETIME", "DATETIMEOFFSET",
                "BIT", "UNIQUEIDENTIFIER", "XML", "SQL_VARIANT",
                "ROWVERSION", "TIMESTAMP", "HIERARCHYID"
            ],
            tableOptions: [
                "ON", "CLUSTERED", "NONCLUSTERED", "WITH", "TEXTIMAGE_ON"
            ],
            regexSyntax: .unsupported,
            booleanLiteralStyle: .numeric,
            likeEscapeStyle: .explicit,
            paginationStyle: .offsetFetch,
            autoLimitStyle: .top
        )

        let mssqlColumnTypes: [String: [String]] = [
            "Integer": ["TINYINT", "SMALLINT", "INT", "BIGINT"],
            "Float": ["FLOAT", "REAL", "DECIMAL", "NUMERIC", "MONEY", "SMALLMONEY"],
            "String": ["CHAR", "VARCHAR", "TEXT", "NCHAR", "NVARCHAR", "NTEXT"],
            "Date": ["DATE", "TIME", "DATETIME", "DATETIME2", "SMALLDATETIME", "DATETIMEOFFSET"],
            "Binary": ["BINARY", "VARBINARY", "IMAGE"],
            "Boolean": ["BIT"],
            "XML": ["XML"],
            "UUID": ["UNIQUEIDENTIFIER"],
            "Spatial": ["GEOMETRY", "GEOGRAPHY"],
            "Other": ["SQL_VARIANT", "TIMESTAMP", "ROWVERSION", "CURSOR", "TABLE", "HIERARCHYID"]
        ]

        let oracleDialect = SQLDialectDescriptor(
            identifierQuote: "\"",
            keywords: [
                "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "CROSS", "FULL",
                "ON", "USING", "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN", "AS",
                "ORDER", "BY", "GROUP", "HAVING", "FETCH", "FIRST", "ROWS", "ONLY", "OFFSET",
                "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "MERGE",
                "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "DATABASE", "SCHEMA",
                "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CONSTRAINT",
                "ADD", "MODIFY", "COLUMN", "RENAME",
                "NULL", "IS", "ASC", "DESC", "DISTINCT", "ALL", "ANY", "SOME",
                "SEQUENCE", "SYNONYM", "GRANT", "REVOKE", "TRIGGER", "PROCEDURE",
                "CASE", "WHEN", "THEN", "ELSE", "END", "COALESCE", "NULLIF", "DECODE",
                "UNION", "INTERSECT", "MINUS",
                "DECLARE", "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT",
                "EXECUTE", "IMMEDIATE",
                "OVER", "PARTITION", "ROW_NUMBER", "RANK", "DENSE_RANK",
                "RETURNING", "CONNECT", "LEVEL", "START", "WITH", "PRIOR",
                "ROWNUM", "ROWID", "DUAL", "SYSDATE", "SYSTIMESTAMP"
            ],
            functions: [
                "COUNT", "SUM", "AVG", "MAX", "MIN", "LISTAGG",
                "CONCAT", "SUBSTR", "INSTR", "LENGTH", "LOWER", "UPPER",
                "TRIM", "LTRIM", "RTRIM", "REPLACE", "LPAD", "RPAD",
                "INITCAP", "TRANSLATE",
                "SYSDATE", "SYSTIMESTAMP", "CURRENT_DATE", "CURRENT_TIMESTAMP",
                "ADD_MONTHS", "MONTHS_BETWEEN", "LAST_DAY", "NEXT_DAY",
                "EXTRACT", "TO_DATE", "TO_CHAR", "TO_NUMBER", "TO_TIMESTAMP",
                "TRUNC", "ROUND",
                "CEIL", "FLOOR", "ABS", "POWER", "SQRT", "MOD", "SIGN",
                "NVL", "NVL2", "DECODE", "COALESCE", "NULLIF",
                "GREATEST", "LEAST", "CAST",
                "SYS_GUID", "DBMS_RANDOM.VALUE", "USER", "SYS_CONTEXT"
            ],
            dataTypes: [
                "NUMBER", "INTEGER", "SMALLINT", "FLOAT", "BINARY_FLOAT", "BINARY_DOUBLE",
                "CHAR", "VARCHAR2", "NCHAR", "NVARCHAR2", "CLOB", "NCLOB", "LONG",
                "BLOB", "RAW", "LONG RAW", "BFILE",
                "DATE", "TIMESTAMP", "TIMESTAMP WITH TIME ZONE", "TIMESTAMP WITH LOCAL TIME ZONE",
                "INTERVAL YEAR TO MONTH", "INTERVAL DAY TO SECOND",
                "BOOLEAN", "ROWID", "UROWID", "XMLTYPE", "SDO_GEOMETRY"
            ],
            tableOptions: [
                "TABLESPACE", "PCTFREE", "INITRANS"
            ],
            regexSyntax: .regexpLike,
            booleanLiteralStyle: .numeric,
            likeEscapeStyle: .explicit,
            paginationStyle: .offsetFetch,
            offsetFetchOrderBy: "ORDER BY 1",
            autoLimitStyle: .fetchFirst
        )

        let oracleColumnTypes: [String: [String]] = [
            "Integer": ["NUMBER", "INTEGER", "INT", "SMALLINT"],
            "Float": ["FLOAT", "BINARY_FLOAT", "BINARY_DOUBLE", "DECIMAL", "NUMERIC", "REAL", "DOUBLE PRECISION"],
            "String": ["VARCHAR2", "NVARCHAR2", "CHAR", "NCHAR", "CLOB", "NCLOB", "LONG"],
            "Date": [
                "DATE", "TIMESTAMP", "TIMESTAMP WITH TIME ZONE", "TIMESTAMP WITH LOCAL TIME ZONE",
                "INTERVAL YEAR TO MONTH", "INTERVAL DAY TO SECOND"
            ],
            "Binary": ["RAW", "LONG RAW", "BLOB", "BFILE"],
            "Boolean": [],
            "XML": ["XMLTYPE"],
            "Spatial": ["SDO_GEOMETRY"],
            "Other": ["ROWID", "UROWID"]
        ]

        let duckdbDialect = SQLDialectDescriptor(
            identifierQuote: "\"",
            keywords: [
                "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "CROSS", "FULL",
                "ON", "USING", "AND", "OR", "NOT", "IN", "LIKE", "ILIKE", "BETWEEN", "AS",
                "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET", "FETCH", "FIRST", "ROWS", "ONLY",
                "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
                "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "DATABASE", "SCHEMA",
                "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CONSTRAINT",
                "ADD", "MODIFY", "COLUMN", "RENAME",
                "NULL", "IS", "ASC", "DESC", "DISTINCT", "ALL", "ANY", "SOME",
                "CASE", "WHEN", "THEN", "ELSE", "END", "COALESCE", "NULLIF",
                "UNION", "INTERSECT", "EXCEPT",
                "COPY", "PRAGMA", "DESCRIBE", "SUMMARIZE", "PIVOT", "UNPIVOT",
                "QUALIFY", "SAMPLE", "TABLESAMPLE", "RETURNING",
                "INSTALL", "LOAD", "FORCE", "ATTACH", "DETACH",
                "EXPORT", "IMPORT",
                "WITH", "RECURSIVE", "MATERIALIZED",
                "EXPLAIN", "ANALYZE",
                "WINDOW", "OVER", "PARTITION"
            ],
            functions: [
                "COUNT", "SUM", "AVG", "MAX", "MIN",
                "LIST_AGG", "STRING_AGG", "ARRAY_AGG",
                "CONCAT", "SUBSTRING", "LEFT", "RIGHT", "LENGTH", "LOWER", "UPPER",
                "TRIM", "LTRIM", "RTRIM", "REPLACE", "SPLIT_PART",
                "NOW", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP",
                "DATE_TRUNC", "EXTRACT", "AGE", "TO_CHAR", "TO_DATE",
                "EPOCH_MS",
                "ROUND", "CEIL", "CEILING", "FLOOR", "ABS", "MOD", "POW", "POWER", "SQRT",
                "CAST",
                "REGEXP_MATCHES", "READ_CSV", "READ_PARQUET", "READ_JSON",
                "GLOB", "STRUCT_PACK", "LIST_VALUE", "MAP", "UNNEST",
                "GENERATE_SERIES", "RANGE"
            ],
            dataTypes: [
                "INTEGER", "BIGINT", "HUGEINT", "UHUGEINT",
                "DOUBLE", "FLOAT", "DECIMAL",
                "VARCHAR", "TEXT", "BLOB",
                "BOOLEAN",
                "DATE", "TIME", "TIMESTAMP", "TIMESTAMP WITH TIME ZONE", "INTERVAL",
                "UUID", "JSON",
                "LIST", "MAP", "STRUCT", "UNION", "ENUM", "BIT"
            ],
            regexSyntax: .regexpMatches,
            booleanLiteralStyle: .truefalse,
            likeEscapeStyle: .explicit,
            paginationStyle: .limit
        )

        let duckdbColumnTypes: [String: [String]] = [
            "Integer": [
                "TINYINT", "SMALLINT", "INTEGER", "BIGINT", "HUGEINT",
                "UTINYINT", "USMALLINT", "UINTEGER", "UBIGINT"
            ],
            "Float": ["FLOAT", "DOUBLE", "DECIMAL", "NUMERIC"],
            "String": ["VARCHAR", "TEXT", "CHAR", "BPCHAR"],
            "Date": [
                "DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ",
                "TIMESTAMP_S", "TIMESTAMP_MS", "TIMESTAMP_NS", "INTERVAL"
            ],
            "Binary": ["BLOB", "BYTEA", "BIT", "BITSTRING"],
            "Boolean": ["BOOLEAN"],
            "JSON": ["JSON"],
            "UUID": ["UUID"],
            "List": ["LIST"],
            "Struct": ["STRUCT"],
            "Map": ["MAP"],
            "Union": ["UNION"],
            "Enum": ["ENUM"]
        ]

        let cassandraDialect = SQLDialectDescriptor(
            identifierQuote: "\"",
            keywords: [
                "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "AS",
                "ORDER", "BY", "LIMIT",
                "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
                "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW",
                "PRIMARY", "KEY", "ADD", "COLUMN", "RENAME",
                "NULL", "IS", "ASC", "DESC", "DISTINCT",
                "CASE", "WHEN", "THEN", "ELSE", "END",
                "KEYSPACE", "USE", "TRUNCATE", "BATCH", "GRANT", "REVOKE",
                "CLUSTERING", "PARTITION", "TTL", "WRITETIME",
                "ALLOW FILTERING", "IF NOT EXISTS", "IF EXISTS",
                "USING TIMESTAMP", "USING TTL",
                "MATERIALIZED VIEW", "CONTAINS", "FROZEN", "COUNTER", "TOKEN"
            ],
            functions: [
                "COUNT", "SUM", "AVG", "MAX", "MIN",
                "NOW", "UUID", "TOTIMESTAMP", "TOKEN", "TTL", "WRITETIME",
                "MINTIMEUUID", "MAXTIMEUUID", "TODATE", "TOUNIXTIMESTAMP",
                "CAST"
            ],
            dataTypes: [
                "TEXT", "VARCHAR", "ASCII",
                "INT", "BIGINT", "SMALLINT", "TINYINT", "VARINT",
                "FLOAT", "DOUBLE", "DECIMAL",
                "BOOLEAN", "UUID", "TIMEUUID",
                "TIMESTAMP", "DATE", "TIME",
                "BLOB", "INET", "COUNTER",
                "LIST", "SET", "MAP", "TUPLE", "FROZEN"
            ],
            regexSyntax: .unsupported,
            booleanLiteralStyle: .truefalse,
            likeEscapeStyle: .explicit,
            paginationStyle: .limit,
            autoLimitStyle: .limit
        )

        let cassandraColumnTypes: [String: [String]] = [
            "Numeric": [
                "TINYINT", "SMALLINT", "INT", "BIGINT", "VARINT",
                "FLOAT", "DOUBLE", "DECIMAL", "COUNTER"
            ],
            "String": ["TEXT", "VARCHAR", "ASCII"],
            "Date": ["TIMESTAMP", "DATE", "TIME"],
            "Binary": ["BLOB"],
            "Boolean": ["BOOLEAN"],
            "Other": ["UUID", "TIMEUUID", "INET", "LIST", "SET", "MAP", "TUPLE", "FROZEN"]
        ]

        let mongoCompletions: [CompletionEntry] = [
            CompletionEntry(label: "db.", insertText: "db."),
            CompletionEntry(label: "db.runCommand", insertText: "db.runCommand"),
            CompletionEntry(label: "db.adminCommand", insertText: "db.adminCommand"),
            CompletionEntry(label: "db.createView", insertText: "db.createView"),
            CompletionEntry(label: "db.createCollection", insertText: "db.createCollection"),
            CompletionEntry(label: "show dbs", insertText: "show dbs"),
            CompletionEntry(label: "show collections", insertText: "show collections"),
            CompletionEntry(label: ".find", insertText: ".find"),
            CompletionEntry(label: ".findOne", insertText: ".findOne"),
            CompletionEntry(label: ".aggregate", insertText: ".aggregate"),
            CompletionEntry(label: ".insertOne", insertText: ".insertOne"),
            CompletionEntry(label: ".insertMany", insertText: ".insertMany"),
            CompletionEntry(label: ".updateOne", insertText: ".updateOne"),
            CompletionEntry(label: ".updateMany", insertText: ".updateMany"),
            CompletionEntry(label: ".deleteOne", insertText: ".deleteOne"),
            CompletionEntry(label: ".deleteMany", insertText: ".deleteMany"),
            CompletionEntry(label: ".replaceOne", insertText: ".replaceOne"),
            CompletionEntry(label: ".findOneAndUpdate", insertText: ".findOneAndUpdate"),
            CompletionEntry(label: ".findOneAndReplace", insertText: ".findOneAndReplace"),
            CompletionEntry(label: ".findOneAndDelete", insertText: ".findOneAndDelete"),
            CompletionEntry(label: ".countDocuments", insertText: ".countDocuments"),
            CompletionEntry(label: ".createIndex", insertText: ".createIndex")
        ]

        let mongoColumnTypes: [String: [String]] = [
            "String": ["string", "objectId", "regex"],
            "Number": ["int", "long", "double", "decimal"],
            "Date": ["date", "timestamp"],
            "Binary": ["binData"],
            "Boolean": ["bool"],
            "Array": ["array"],
            "Object": ["object"],
            "Null": ["null"],
            "Other": ["javascript", "minKey", "maxKey"]
        ]

        let etcdCompletions: [CompletionEntry] = [
            CompletionEntry(label: "get", insertText: "get"),
            CompletionEntry(label: "put", insertText: "put"),
            CompletionEntry(label: "del", insertText: "del"),
            CompletionEntry(label: "watch", insertText: "watch"),
            CompletionEntry(label: "lease grant", insertText: "lease grant"),
            CompletionEntry(label: "lease revoke", insertText: "lease revoke"),
            CompletionEntry(label: "lease timetolive", insertText: "lease timetolive"),
            CompletionEntry(label: "lease list", insertText: "lease list"),
            CompletionEntry(label: "lease keep-alive", insertText: "lease keep-alive"),
            CompletionEntry(label: "member list", insertText: "member list"),
            CompletionEntry(label: "endpoint status", insertText: "endpoint status"),
            CompletionEntry(label: "endpoint health", insertText: "endpoint health"),
            CompletionEntry(label: "compaction", insertText: "compaction"),
            CompletionEntry(label: "auth enable", insertText: "auth enable"),
            CompletionEntry(label: "auth disable", insertText: "auth disable"),
            CompletionEntry(label: "user add", insertText: "user add"),
            CompletionEntry(label: "user delete", insertText: "user delete"),
            CompletionEntry(label: "user list", insertText: "user list"),
            CompletionEntry(label: "role add", insertText: "role add"),
            CompletionEntry(label: "role delete", insertText: "role delete"),
            CompletionEntry(label: "role list", insertText: "role list"),
            CompletionEntry(label: "user grant-role", insertText: "user grant-role"),
            CompletionEntry(label: "user revoke-role", insertText: "user revoke-role"),
            CompletionEntry(label: "--prefix", insertText: "--prefix"),
            CompletionEntry(label: "--limit", insertText: "--limit="),
            CompletionEntry(label: "--keys-only", insertText: "--keys-only"),
            CompletionEntry(label: "--lease", insertText: "--lease="),
        ]

        let redisCompletions: [CompletionEntry] = [
            CompletionEntry(label: "GET", insertText: "GET"),
            CompletionEntry(label: "SET", insertText: "SET"),
            CompletionEntry(label: "DEL", insertText: "DEL"),
            CompletionEntry(label: "EXISTS", insertText: "EXISTS"),
            CompletionEntry(label: "KEYS", insertText: "KEYS"),
            CompletionEntry(label: "HGET", insertText: "HGET"),
            CompletionEntry(label: "HSET", insertText: "HSET"),
            CompletionEntry(label: "HGETALL", insertText: "HGETALL"),
            CompletionEntry(label: "HDEL", insertText: "HDEL"),
            CompletionEntry(label: "LPUSH", insertText: "LPUSH"),
            CompletionEntry(label: "RPUSH", insertText: "RPUSH"),
            CompletionEntry(label: "LRANGE", insertText: "LRANGE"),
            CompletionEntry(label: "LLEN", insertText: "LLEN"),
            CompletionEntry(label: "SADD", insertText: "SADD"),
            CompletionEntry(label: "SMEMBERS", insertText: "SMEMBERS"),
            CompletionEntry(label: "SREM", insertText: "SREM"),
            CompletionEntry(label: "SCARD", insertText: "SCARD"),
            CompletionEntry(label: "ZADD", insertText: "ZADD"),
            CompletionEntry(label: "ZRANGE", insertText: "ZRANGE"),
            CompletionEntry(label: "ZREM", insertText: "ZREM"),
            CompletionEntry(label: "ZSCORE", insertText: "ZSCORE"),
            CompletionEntry(label: "EXPIRE", insertText: "EXPIRE"),
            CompletionEntry(label: "TTL", insertText: "TTL"),
            CompletionEntry(label: "PERSIST", insertText: "PERSIST"),
            CompletionEntry(label: "TYPE", insertText: "TYPE"),
            CompletionEntry(label: "SCAN", insertText: "SCAN"),
            CompletionEntry(label: "HSCAN", insertText: "HSCAN"),
            CompletionEntry(label: "SSCAN", insertText: "SSCAN"),
            CompletionEntry(label: "ZSCAN", insertText: "ZSCAN"),
            CompletionEntry(label: "INFO", insertText: "INFO"),
            CompletionEntry(label: "DBSIZE", insertText: "DBSIZE"),
            CompletionEntry(label: "FLUSHDB", insertText: "FLUSHDB"),
            CompletionEntry(label: "SELECT", insertText: "SELECT"),
            CompletionEntry(label: "INCR", insertText: "INCR"),
            CompletionEntry(label: "DECR", insertText: "DECR"),
            CompletionEntry(label: "APPEND", insertText: "APPEND"),
            CompletionEntry(label: "MGET", insertText: "MGET"),
            CompletionEntry(label: "MSET", insertText: "MSET")
        ]

        let redisColumnTypes: [String: [String]] = [
            "String": ["string"],
            "List": ["list"],
            "Set": ["set"],
            "Sorted Set": ["zset"],
            "Hash": ["hash"],
            "Stream": ["stream"],
            "HyperLogLog": ["hyperloglog"],
            "Bitmap": ["bitmap"],
            "Geospatial": ["geo"]
        ]

        let d1Dialect = SQLDialectDescriptor(
            identifierQuote: "\"",
            keywords: [
                "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "CROSS",
                "ON", "AND", "OR", "NOT", "IN", "LIKE", "GLOB", "BETWEEN", "AS",
                "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET",
                "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
                "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "TRIGGER",
                "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CONSTRAINT",
                "ADD", "COLUMN", "RENAME",
                "NULL", "IS", "ASC", "DESC", "DISTINCT", "ALL",
                "CASE", "WHEN", "THEN", "ELSE", "END", "COALESCE", "IFNULL", "NULLIF",
                "UNION", "INTERSECT", "EXCEPT",
                "AUTOINCREMENT", "WITHOUT", "ROWID", "PRAGMA",
                "REPLACE", "ABORT", "FAIL", "IGNORE", "ROLLBACK",
                "TEMP", "TEMPORARY", "VACUUM", "EXPLAIN", "QUERY", "PLAN"
            ],
            functions: [
                "COUNT", "SUM", "AVG", "MAX", "MIN", "GROUP_CONCAT", "TOTAL",
                "LENGTH", "SUBSTR", "SUBSTRING", "LOWER", "UPPER", "TRIM", "LTRIM", "RTRIM",
                "REPLACE", "INSTR", "PRINTF",
                "DATE", "TIME", "DATETIME", "JULIANDAY", "STRFTIME",
                "ABS", "ROUND", "RANDOM",
                "CAST", "TYPEOF",
                "COALESCE", "IFNULL", "NULLIF", "HEX", "QUOTE"
            ],
            dataTypes: [
                "INTEGER", "REAL", "TEXT", "BLOB", "NUMERIC",
                "INT", "TINYINT", "SMALLINT", "MEDIUMINT", "BIGINT",
                "UNSIGNED", "BIG", "INT2", "INT8",
                "CHARACTER", "VARCHAR", "VARYING", "NCHAR", "NATIVE",
                "NVARCHAR", "CLOB",
                "DOUBLE", "PRECISION", "FLOAT",
                "DECIMAL", "BOOLEAN", "DATE", "DATETIME"
            ],
            tableOptions: ["WITHOUT ROWID", "STRICT"],
            regexSyntax: .unsupported,
            booleanLiteralStyle: .numeric,
            likeEscapeStyle: .explicit,
            paginationStyle: .limit
        )

        let d1ColumnTypes: [String: [String]] = [
            "Integer": ["INTEGER", "INT", "TINYINT", "SMALLINT", "MEDIUMINT", "BIGINT"],
            "Float": ["REAL", "DOUBLE", "FLOAT", "NUMERIC", "DECIMAL"],
            "String": ["TEXT", "VARCHAR", "CHARACTER", "CHAR", "CLOB", "NVARCHAR", "NCHAR"],
            "Date": ["DATE", "TIME", "DATETIME", "TIMESTAMP"],
            "Binary": ["BLOB"],
            "Boolean": ["BOOLEAN"]
        ]

        return [
            ("MongoDB", PluginMetadataSnapshot(
                displayName: "MongoDB", iconName: "mongodb-icon", defaultPort: 27_017,
                requiresAuthentication: false, supportsForeignKeys: false, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "mongodb", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["mongodb", "mongodb+srv"], postConnectActions: [],
                brandColorHex: "#00ED63",
                queryLanguageName: "MQL", editorLanguage: .javascript,
                connectionMode: .network, supportsDatabaseSwitching: true,
                supportsColumnReorder: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: true,
                    supportsExport: true,
                    supportsSSH: true,
                    supportsSSL: true,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: false,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "main",
                    tableEntityName: "Collections",
                    defaultPrimaryKeyColumn: "_id",
                    immutableColumns: ["_id"],
                    systemDatabaseNames: ["admin", "local", "config"],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .flat,
                    structureColumnFields: [.name, .type, .nullable]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: nil,
                    statementCompletions: mongoCompletions,
                    columnTypesByCategory: mongoColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [
                        ConnectionField(
                            id: "mongoAuthSource", label: "Auth Database", placeholder: "admin"
                        ),
                        ConnectionField(
                            id: "mongoReadPreference",
                            label: "Read Preference",
                            fieldType: .dropdown(options: [
                                .init(value: "", label: "Default"),
                                .init(value: "primary", label: "Primary"),
                                .init(value: "primaryPreferred", label: "Primary Preferred"),
                                .init(value: "secondary", label: "Secondary"),
                                .init(value: "secondaryPreferred", label: "Secondary Preferred"),
                                .init(value: "nearest", label: "Nearest")
                            ])
                        ),
                        ConnectionField(
                            id: "mongoWriteConcern",
                            label: "Write Concern",
                            fieldType: .dropdown(options: [
                                .init(value: "", label: "Default"),
                                .init(value: "majority", label: "Majority"),
                                .init(value: "1", label: "1"),
                                .init(value: "2", label: "2"),
                                .init(value: "3", label: "3")
                            ])
                        )
                    ]
                )
            )),
            ("Redis", PluginMetadataSnapshot(
                displayName: "Redis", iconName: "redis-icon", defaultPort: 6_379,
                requiresAuthentication: false, supportsForeignKeys: false, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "redis", parameterStyle: .questionMark,
                navigationModel: .inPlace, explainVariants: [], pathFieldRole: .databaseIndex,
                supportsHealthMonitor: true, urlSchemes: ["redis", "rediss"],
                postConnectActions: [.selectDatabaseFromConnectionField(fieldId: "redisDatabase")],
                brandColorHex: "#DC382D",
                queryLanguageName: "Redis CLI", editorLanguage: .bash,
                connectionMode: .network, supportsDatabaseSwitching: false,
                supportsColumnReorder: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: false,
                    supportsExport: true,
                    supportsSSH: true,
                    supportsSSL: true,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: false,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "db0",
                    tableEntityName: "Keys",
                    defaultPrimaryKeyColumn: "Key",
                    immutableColumns: [],
                    systemDatabaseNames: [],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .flat,
                    structureColumnFields: [.name, .type, .nullable]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: nil,
                    statementCompletions: redisCompletions,
                    columnTypesByCategory: redisColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [
                        ConnectionField(
                            id: "redisDatabase",
                            label: String(localized: "Database Index"),
                            defaultValue: "0",
                            fieldType: .stepper(range: ConnectionField.IntRange(0...15))
                        )
                    ]
                )
            )),
            ("SQL Server", PluginMetadataSnapshot(
                displayName: "SQL Server", iconName: "mssql-icon", defaultPort: 1_433,
                requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: true,
                isDownloadable: true, primaryUrlScheme: "sqlserver", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["sqlserver", "mssql"],
                postConnectActions: [.selectDatabaseFromLastSession],
                brandColorHex: "#E34517",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .network, supportsDatabaseSwitching: true,
                supportsColumnReorder: false,
                capabilities: .defaults,
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "dbo",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: ["master", "tempdb", "model", "msdb"],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .bySchema,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue, .autoIncrement, .comment]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: mssqlDialect,
                    statementCompletions: [],
                    columnTypesByCategory: mssqlColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [
                        ConnectionField(
                            id: "mssqlSchema", label: "Schema", placeholder: "dbo", defaultValue: "dbo"
                        )
                    ]
                )
            )),
            ("Oracle", PluginMetadataSnapshot(
                displayName: "Oracle", iconName: "oracle-icon", defaultPort: 1_521,
                requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: true,
                isDownloadable: true, primaryUrlScheme: "oracle", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .serviceName,
                supportsHealthMonitor: true, urlSchemes: ["oracle"], postConnectActions: [],
                brandColorHex: "#C3160B",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .network, supportsDatabaseSwitching: true,
                supportsColumnReorder: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: true,
                    supportsExport: true,
                    supportsSSH: true,
                    supportsSSL: true,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: [
                        "SYS", "SYSTEM", "OUTLN", "DBSNMP", "APPQOSSYS", "WMSYS", "XDB"
                    ],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .bySchema,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue, .autoIncrement, .comment]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: oracleDialect,
                    statementCompletions: [],
                    columnTypesByCategory: oracleColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [
                        ConnectionField(
                            id: "oracleServiceName", label: "Service Name", placeholder: "ORCL"
                        )
                    ]
                )
            )),
            ("ClickHouse", PluginMetadataSnapshot(
                displayName: "ClickHouse", iconName: "clickhouse-icon", defaultPort: 8_123,
                requiresAuthentication: true, supportsForeignKeys: false, supportsSchemaEditing: true,
                isDownloadable: true, primaryUrlScheme: "clickhouse", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [
                    ExplainVariant(id: "plan", label: "Plan", sqlPrefix: "EXPLAIN"),
                    ExplainVariant(id: "pipeline", label: "Pipeline", sqlPrefix: "EXPLAIN PIPELINE"),
                    ExplainVariant(id: "ast", label: "AST", sqlPrefix: "EXPLAIN AST"),
                    ExplainVariant(id: "syntax", label: "Syntax", sqlPrefix: "EXPLAIN SYNTAX"),
                    ExplainVariant(id: "estimate", label: "Estimate", sqlPrefix: "EXPLAIN ESTIMATE")
                ],
                pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["clickhouse", "ch"], postConnectActions: [],
                brandColorHex: "#FFD100",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .network, supportsDatabaseSwitching: true,
                supportsColumnReorder: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: true,
                    supportsExport: true,
                    supportsSSH: true,
                    supportsSSL: true,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: true,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: true,
                    requiresReconnectForDatabaseSwitch: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: ["information_schema", "INFORMATION_SCHEMA", "system"],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .byDatabase,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue, .comment]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: clickhouseDialect,
                    statementCompletions: [],
                    columnTypesByCategory: clickhouseColumnTypes
                ),
                connection: .defaults
            )),
            ("DuckDB", PluginMetadataSnapshot(
                displayName: "DuckDB", iconName: "duckdb-icon", defaultPort: 0,
                requiresAuthentication: false, supportsForeignKeys: true, supportsSchemaEditing: true,
                isDownloadable: true, primaryUrlScheme: "duckdb", parameterStyle: .dollar,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .filePath,
                supportsHealthMonitor: false, urlSchemes: ["duckdb"], postConnectActions: [],
                brandColorHex: "#FFD900",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .fileBased, supportsDatabaseSwitching: false,
                supportsColumnReorder: false,
                capabilities: .defaults,
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: ["information_schema", "pg_catalog"],
                    systemSchemaNames: [],
                    fileExtensions: ["duckdb", "ddb"],
                    databaseGroupingStrategy: .flat,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue, .autoIncrement, .comment]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: duckdbDialect,
                    statementCompletions: [],
                    columnTypesByCategory: duckdbColumnTypes
                ),
                connection: .defaults
            )),
            ("Cassandra", PluginMetadataSnapshot(
                displayName: "Cassandra / ScyllaDB", iconName: "cassandra-icon", defaultPort: 9_042,
                requiresAuthentication: false, supportsForeignKeys: false, supportsSchemaEditing: true,
                isDownloadable: true, primaryUrlScheme: "cassandra", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["cassandra", "cql", "scylladb", "scylla"],
                postConnectActions: [],
                brandColorHex: "#26A0D8",
                queryLanguageName: "CQL", editorLanguage: .sql,
                connectionMode: .network, supportsDatabaseSwitching: true,
                supportsColumnReorder: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: false,
                    supportsExport: true,
                    supportsSSH: true,
                    supportsSSL: true,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "default",
                    tableEntityName: "Tables",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: [
                        "system", "system_schema", "system_auth",
                        "system_distributed", "system_traces", "system_virtual_schema"
                    ],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .byDatabase,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue, .autoIncrement, .comment]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: cassandraDialect,
                    statementCompletions: [],
                    columnTypesByCategory: cassandraColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [
                        ConnectionField(
                            id: "sslCaCertPath",
                            label: "CA Certificate",
                            placeholder: "/path/to/ca-cert.pem",
                            section: .advanced
                        )
                    ]
                )
            )),
            ("ScyllaDB", PluginMetadataSnapshot(
                displayName: "ScyllaDB", iconName: "scylladb-icon", defaultPort: 9_042,
                requiresAuthentication: false, supportsForeignKeys: false, supportsSchemaEditing: true,
                isDownloadable: true, primaryUrlScheme: "scylladb", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["scylladb", "scylla"],
                postConnectActions: [],
                brandColorHex: "#6B2EE3",
                queryLanguageName: "CQL", editorLanguage: .sql,
                connectionMode: .network, supportsDatabaseSwitching: true,
                supportsColumnReorder: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: false,
                    supportsExport: true,
                    supportsSSH: true,
                    supportsSSL: true,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "default",
                    tableEntityName: "Tables",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: [
                        "system", "system_schema", "system_auth",
                        "system_distributed", "system_traces", "system_virtual_schema"
                    ],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .byDatabase,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue, .autoIncrement, .comment]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: cassandraDialect,
                    statementCompletions: [],
                    columnTypesByCategory: cassandraColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [
                        ConnectionField(
                            id: "sslCaCertPath",
                            label: "CA Certificate",
                            placeholder: "/path/to/ca-cert.pem",
                            section: .advanced
                        )
                    ]
                )
            )),
            ("etcd", PluginMetadataSnapshot(
                displayName: "etcd", iconName: "etcd-icon", defaultPort: 2_379,
                requiresAuthentication: false, supportsForeignKeys: false, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "etcd", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["etcd", "etcds"], postConnectActions: [],
                brandColorHex: "#419EDA",
                queryLanguageName: "etcdctl", editorLanguage: .bash,
                connectionMode: .network, supportsDatabaseSwitching: false,
                supportsColumnReorder: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: false,
                    supportsExport: true,
                    supportsSSH: true,
                    supportsSSL: true,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: false,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "public",
                    defaultGroupName: "main",
                    tableEntityName: "Keys",
                    defaultPrimaryKeyColumn: "Key",
                    immutableColumns: ["Version", "ModRevision", "CreateRevision"],
                    systemDatabaseNames: [],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .flat,
                    structureColumnFields: [.name, .type, .nullable]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: nil,
                    statementCompletions: etcdCompletions,
                    columnTypesByCategory: ["String": ["string"]]
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [
                        ConnectionField(
                            id: "etcdKeyPrefix",
                            label: String(localized: "Key Prefix Root"),
                            placeholder: "/",
                            section: .advanced
                        ),
                        ConnectionField(
                            id: "etcdTlsMode",
                            label: String(localized: "TLS Mode"),
                            fieldType: .dropdown(options: [
                                .init(value: "Disabled", label: "Disabled"),
                                .init(value: "Required", label: String(localized: "Required (skip verify)")),
                                .init(value: "VerifyCA", label: String(localized: "Verify CA")),
                                .init(value: "VerifyIdentity", label: String(localized: "Verify Identity")),
                            ]),
                            section: .advanced
                        ),
                        ConnectionField(
                            id: "etcdCaCertPath",
                            label: String(localized: "CA Certificate"),
                            placeholder: "/path/to/ca.pem",
                            section: .advanced
                        ),
                        ConnectionField(
                            id: "etcdClientCertPath",
                            label: String(localized: "Client Certificate"),
                            placeholder: "/path/to/client.pem",
                            section: .advanced
                        ),
                        ConnectionField(
                            id: "etcdClientKeyPath",
                            label: String(localized: "Client Key"),
                            placeholder: "/path/to/client-key.pem",
                            section: .advanced
                        ),
                    ]
                )
            )),
            ("Cloudflare D1", PluginMetadataSnapshot(
                displayName: "Cloudflare D1", iconName: "cloudflare-d1-icon", defaultPort: 0,
                requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "d1", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [
                    ExplainVariant(id: "plan", label: "Query Plan", sqlPrefix: "EXPLAIN QUERY PLAN")
                ],
                pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: ["d1"], postConnectActions: [],
                brandColorHex: "#F6821F",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .apiOnly, supportsDatabaseSwitching: true,
                supportsColumnReorder: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: false,
                    supportsExport: true,
                    supportsSSH: false,
                    supportsSSL: false,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: true,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "main",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: [],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .flat,
                    structureColumnFields: [.name, .type, .nullable, .defaultValue]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: d1Dialect,
                    statementCompletions: [],
                    columnTypesByCategory: d1ColumnTypes
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [
                        ConnectionField(
                            id: "cfAccountId",
                            label: String(localized: "Account ID"),
                            placeholder: "Cloudflare Account ID",
                            required: true,
                            section: .authentication
                        )
                    ]
                )
            )),
            ("DynamoDB", PluginMetadataSnapshot(
                displayName: "Amazon DynamoDB", iconName: "dynamodb-icon", defaultPort: 0,
                requiresAuthentication: true, supportsForeignKeys: false, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [],
                pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: [], postConnectActions: [],
                brandColorHex: "#4053D6",
                queryLanguageName: "PartiQL", editorLanguage: .sql,
                connectionMode: .apiOnly, supportsDatabaseSwitching: false,
                supportsColumnReorder: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: false,
                    supportsExport: true,
                    supportsSSH: false,
                    supportsSSL: false,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "",
                    defaultGroupName: "main",
                    tableEntityName: "Tables",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: [],
                    systemSchemaNames: [],
                    fileExtensions: [],
                    databaseGroupingStrategy: .flat,
                    structureColumnFields: [.name, .type]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: SQLDialectDescriptor(
                        identifierQuote: "\"",
                        keywords: [
                            "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUE", "SET",
                            "UPDATE", "DELETE", "AND", "OR", "NOT", "IN", "BETWEEN",
                            "EXISTS", "MISSING", "IS", "NULL", "LIMIT",
                        ],
                        functions: [
                            "begins_with", "contains", "size", "attribute_type",
                            "attribute_exists", "attribute_not_exists",
                        ],
                        dataTypes: ["S", "N", "B", "BOOL", "NULL", "L", "M", "SS", "NS", "BS"]
                    ),
                    statementCompletions: [
                        CompletionEntry(label: "SELECT", insertText: "SELECT"),
                        CompletionEntry(label: "INSERT INTO", insertText: "INSERT INTO"),
                        CompletionEntry(label: "UPDATE", insertText: "UPDATE"),
                        CompletionEntry(label: "DELETE FROM", insertText: "DELETE FROM"),
                        CompletionEntry(label: "VALUE", insertText: "VALUE"),
                        CompletionEntry(label: "SET", insertText: "SET"),
                        CompletionEntry(label: "WHERE", insertText: "WHERE"),
                        CompletionEntry(label: "begins_with", insertText: "begins_with"),
                        CompletionEntry(label: "contains", insertText: "contains"),
                        CompletionEntry(label: "size", insertText: "size"),
                        CompletionEntry(label: "attribute_type", insertText: "attribute_type"),
                        CompletionEntry(label: "attribute_exists", insertText: "attribute_exists"),
                        CompletionEntry(label: "attribute_not_exists", insertText: "attribute_not_exists"),
                    ],
                    columnTypesByCategory: [
                        "String": ["S"],
                        "Number": ["N"],
                        "Binary": ["B"],
                        "Boolean": ["BOOL"],
                        "Null": ["NULL"],
                        "List": ["L"],
                        "Map": ["M"],
                        "String Set": ["SS"],
                        "Number Set": ["NS"],
                        "Binary Set": ["BS"],
                    ]
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [
                        ConnectionField(
                            id: "awsAuthMethod",
                            label: String(localized: "Auth Method"),
                            defaultValue: "credentials",
                            fieldType: .dropdown(options: [
                                .init(value: "credentials", label: "Access Key + Secret Key"),
                                .init(value: "profile", label: "AWS Profile"),
                                .init(value: "sso", label: "AWS SSO"),
                            ]),
                            section: .authentication
                        ),
                        ConnectionField(
                            id: "awsAccessKeyId",
                            label: String(localized: "Access Key ID"),
                            placeholder: "AKIA...",
                            section: .authentication,
                            visibleWhen: FieldVisibilityRule(fieldId: "awsAuthMethod", values: ["credentials"])
                        ),
                        ConnectionField(
                            id: "awsSecretAccessKey",
                            label: String(localized: "Secret Access Key"),
                            placeholder: "wJalr...",
                            fieldType: .secure,
                            section: .authentication,
                            hidesPassword: true,
                            visibleWhen: FieldVisibilityRule(fieldId: "awsAuthMethod", values: ["credentials"])
                        ),
                        ConnectionField(
                            id: "awsSessionToken",
                            label: String(localized: "Session Token"),
                            placeholder: "Optional (for temporary credentials)",
                            fieldType: .secure,
                            section: .authentication,
                            visibleWhen: FieldVisibilityRule(fieldId: "awsAuthMethod", values: ["credentials"])
                        ),
                        ConnectionField(
                            id: "awsProfileName",
                            label: String(localized: "Profile Name"),
                            placeholder: "default",
                            section: .authentication,
                            visibleWhen: FieldVisibilityRule(fieldId: "awsAuthMethod", values: ["profile", "sso"])
                        ),
                        ConnectionField(
                            id: "awsRegion",
                            label: String(localized: "AWS Region"),
                            placeholder: "us-east-1",
                            defaultValue: "us-east-1",
                            fieldType: .text,
                            section: .authentication
                        ),
                        ConnectionField(
                            id: "awsEndpointUrl",
                            label: String(localized: "Custom Endpoint"),
                            placeholder: "http://localhost:8000 (DynamoDB Local)",
                            section: .authentication
                        ),
                    ]
                )
            )),
            ("BigQuery", PluginMetadataSnapshot(
                displayName: "Google BigQuery", iconName: "bigquery-icon", defaultPort: 0,
                requiresAuthentication: true, supportsForeignKeys: false, supportsSchemaEditing: false,
                isDownloadable: true, primaryUrlScheme: "", parameterStyle: .questionMark,
                navigationModel: .standard, explainVariants: [
                    ExplainVariant(id: "dryrun", label: "Dry Run (Cost)", sqlPrefix: "EXPLAIN")
                ],
                pathFieldRole: .database,
                supportsHealthMonitor: true, urlSchemes: [], postConnectActions: [],
                brandColorHex: "#4285F4",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .apiOnly, supportsDatabaseSwitching: false,
                supportsColumnReorder: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: true,
                    supportsImport: false,
                    supportsExport: true,
                    supportsSSH: false,
                    supportsSSL: false,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: false,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false
                ),
                schema: PluginMetadataSnapshot.SchemaInfo(
                    defaultSchemaName: "",
                    defaultGroupName: "default",
                    tableEntityName: "Tables",
                    defaultPrimaryKeyColumn: nil,
                    immutableColumns: [],
                    systemDatabaseNames: [],
                    systemSchemaNames: ["INFORMATION_SCHEMA"],
                    fileExtensions: [],
                    databaseGroupingStrategy: .bySchema,
                    structureColumnFields: [.name, .type, .nullable, .comment]
                ),
                editor: PluginMetadataSnapshot.EditorConfig(
                    sqlDialect: SQLDialectDescriptor(
                        identifierQuote: "`",
                        keywords: [
                            "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET",
                            "DELETE", "CREATE", "DROP", "ALTER", "TABLE", "VIEW", "SCHEMA", "DATABASE",
                            "AND", "OR", "NOT", "IN", "BETWEEN", "EXISTS", "IS", "NULL", "LIKE",
                            "GROUP", "BY", "ORDER", "ASC", "DESC", "HAVING", "LIMIT", "OFFSET",
                            "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS", "ON",
                            "UNION", "ALL", "DISTINCT", "AS", "CASE", "WHEN", "THEN", "ELSE", "END",
                            "WITH", "RECURSIVE", "PARTITION", "OVER", "WINDOW", "ROWS", "RANGE",
                            "UNNEST", "EXCEPT", "INTERSECT", "MERGE", "USING", "MATCHED",
                            "STRUCT", "ARRAY", "TRUE", "FALSE", "CAST", "SAFE_CAST",
                            "IF", "IFNULL", "NULLIF", "COALESCE", "ANY_VALUE",
                            "QUALIFY", "PIVOT", "UNPIVOT", "TABLESAMPLE"
                        ],
                        functions: [
                            "COUNT", "SUM", "AVG", "MIN", "MAX", "APPROX_COUNT_DISTINCT",
                            "ARRAY_AGG", "STRING_AGG", "COUNTIF", "LOGICAL_AND", "LOGICAL_OR",
                            "CONCAT", "LENGTH", "LOWER", "UPPER", "TRIM", "LTRIM", "RTRIM",
                            "SUBSTR", "REPLACE", "REGEXP_CONTAINS", "REGEXP_EXTRACT", "REGEXP_REPLACE",
                            "STARTS_WITH", "ENDS_WITH", "SPLIT", "FORMAT", "REVERSE",
                            "DATE", "TIME", "DATETIME", "TIMESTAMP", "CURRENT_DATE", "CURRENT_TIME",
                            "CURRENT_DATETIME", "CURRENT_TIMESTAMP", "DATE_ADD", "DATE_SUB",
                            "DATE_DIFF", "DATE_TRUNC", "EXTRACT", "FORMAT_DATE", "FORMAT_TIMESTAMP",
                            "PARSE_DATE", "PARSE_TIMESTAMP", "TIMESTAMP_ADD", "TIMESTAMP_SUB",
                            "TIMESTAMP_DIFF", "TIMESTAMP_TRUNC", "UNIX_SECONDS", "UNIX_MILLIS",
                            "CAST", "SAFE_CAST", "PARSE_JSON", "TO_JSON", "TO_JSON_STRING",
                            "JSON_EXTRACT", "JSON_EXTRACT_SCALAR", "JSON_QUERY", "JSON_VALUE",
                            "ARRAY_LENGTH", "GENERATE_ARRAY", "GENERATE_DATE_ARRAY",
                            "ROW_NUMBER", "RANK", "DENSE_RANK", "LAG", "LEAD", "FIRST_VALUE",
                            "LAST_VALUE", "NTILE", "PERCENT_RANK", "CUME_DIST",
                            "ABS", "CEIL", "FLOOR", "ROUND", "TRUNC", "MOD", "SIGN", "SQRT", "POW",
                            "LOG", "ST_GEOGPOINT", "ST_DISTANCE", "ST_CONTAINS", "ST_INTERSECTS",
                            "ML.PREDICT", "ML.EVALUATE", "ML.TRAINING_INFO",
                            "NET.IP_FROM_STRING", "NET.SAFE_IP_FROM_STRING", "NET.HOST",
                            "NET.REG_DOMAIN", "FARM_FINGERPRINT", "MD5", "SHA256", "SHA512"
                        ],
                        dataTypes: [
                            "STRING", "BYTES", "INT64", "FLOAT64", "NUMERIC", "BIGNUMERIC",
                            "BOOL", "TIMESTAMP", "DATE", "TIME", "DATETIME", "INTERVAL",
                            "GEOGRAPHY", "JSON", "STRUCT", "ARRAY", "RANGE"
                        ],
                        regexSyntax: .unsupported,
                        booleanLiteralStyle: .truefalse,
                        likeEscapeStyle: .explicit,
                        paginationStyle: .limit
                    ),
                    statementCompletions: [
                        CompletionEntry(label: "SELECT", insertText: "SELECT"),
                        CompletionEntry(label: "INSERT INTO", insertText: "INSERT INTO"),
                        CompletionEntry(label: "UPDATE", insertText: "UPDATE"),
                        CompletionEntry(label: "DELETE FROM", insertText: "DELETE FROM"),
                        CompletionEntry(label: "CREATE TABLE", insertText: "CREATE TABLE"),
                        CompletionEntry(label: "CREATE VIEW", insertText: "CREATE VIEW"),
                        CompletionEntry(label: "DROP TABLE", insertText: "DROP TABLE"),
                        CompletionEntry(label: "WHERE", insertText: "WHERE"),
                        CompletionEntry(label: "GROUP BY", insertText: "GROUP BY"),
                        CompletionEntry(label: "ORDER BY", insertText: "ORDER BY"),
                        CompletionEntry(label: "LIMIT", insertText: "LIMIT"),
                        CompletionEntry(label: "JOIN", insertText: "JOIN"),
                        CompletionEntry(label: "LEFT JOIN", insertText: "LEFT JOIN"),
                        CompletionEntry(label: "UNION ALL", insertText: "UNION ALL"),
                        CompletionEntry(label: "WITH", insertText: "WITH"),
                        CompletionEntry(label: "UNNEST", insertText: "UNNEST"),
                        CompletionEntry(label: "STRUCT", insertText: "STRUCT"),
                        CompletionEntry(label: "ARRAY", insertText: "ARRAY"),
                        CompletionEntry(label: "QUALIFY", insertText: "QUALIFY"),
                        CompletionEntry(label: "PARTITION BY", insertText: "PARTITION BY"),
                        CompletionEntry(label: "SAFE_CAST", insertText: "SAFE_CAST"),
                        CompletionEntry(label: "REGEXP_CONTAINS", insertText: "REGEXP_CONTAINS"),
                        CompletionEntry(label: "FORMAT_TIMESTAMP", insertText: "FORMAT_TIMESTAMP"),
                        CompletionEntry(label: "ROW_NUMBER", insertText: "ROW_NUMBER"),
                        CompletionEntry(label: "APPROX_COUNT_DISTINCT", insertText: "APPROX_COUNT_DISTINCT")
                    ],
                    columnTypesByCategory: [
                        "Integer": ["INT64"],
                        "Float": ["FLOAT64", "NUMERIC", "BIGNUMERIC"],
                        "String": ["STRING"],
                        "Binary": ["BYTES"],
                        "Boolean": ["BOOL"],
                        "Date/Time": ["DATE", "TIME", "DATETIME", "TIMESTAMP", "INTERVAL"],
                        "Complex": ["STRUCT", "ARRAY", "JSON"],
                        "Geo": ["GEOGRAPHY"],
                        "Range": ["RANGE"]
                    ]
                ),
                connection: PluginMetadataSnapshot.ConnectionConfig(
                    additionalConnectionFields: [
                        ConnectionField(
                            id: "bqAuthMethod",
                            label: String(localized: "Auth Method"),
                            defaultValue: "serviceAccount",
                            fieldType: .dropdown(options: [
                                .init(value: "serviceAccount", label: "Service Account Key"),
                                .init(value: "adc", label: "Application Default Credentials"),
                                .init(value: "oauth", label: "Google Account (OAuth)")
                            ]),
                            section: .authentication
                        ),
                        ConnectionField(
                            id: "bqServiceAccountJson",
                            label: String(localized: "Service Account Key"),
                            placeholder: "File path or paste JSON",
                            required: true,
                            fieldType: .secure,
                            section: .authentication,
                            hidesPassword: true,
                            visibleWhen: FieldVisibilityRule(fieldId: "bqAuthMethod", values: ["serviceAccount"])
                        ),
                        ConnectionField(
                            id: "bqProjectId",
                            label: String(localized: "Project ID"),
                            placeholder: "my-gcp-project",
                            required: true,
                            section: .authentication
                        ),
                        ConnectionField(
                            id: "bqLocation",
                            label: String(localized: "Location"),
                            placeholder: "US, EU, us-central1, etc.",
                            section: .authentication
                        ),
                        ConnectionField(
                            id: "bqOAuthClientId",
                            label: String(localized: "OAuth Client ID"),
                            placeholder: "From GCP Console > Credentials",
                            section: .authentication,
                            visibleWhen: FieldVisibilityRule(fieldId: "bqAuthMethod", values: ["oauth"])
                        ),
                        ConnectionField(
                            id: "bqOAuthClientSecret",
                            label: String(localized: "OAuth Client Secret"),
                            placeholder: "Client secret from GCP Console",
                            fieldType: .secure,
                            section: .authentication,
                            visibleWhen: FieldVisibilityRule(fieldId: "bqAuthMethod", values: ["oauth"])
                        ),
                        ConnectionField(
                            id: "bqMaxBytesBilled",
                            label: String(localized: "Max Bytes Billed"),
                            placeholder: "1000000000",
                            fieldType: .number,
                            section: .advanced
                        )
                    ]
                )
            ))
        ]
    }
    // swiftlint:enable function_body_length
}
