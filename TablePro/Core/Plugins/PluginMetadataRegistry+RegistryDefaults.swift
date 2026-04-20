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
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: true
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
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: false
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
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: true,
                    supportsExport: true,
                    supportsSSH: true,
                    supportsSSL: true,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: true,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: true,
                    supportsRenameColumn: true
                ),
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
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: false,
                    supportsRenameColumn: true
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
                supportsHealthMonitor: true, urlSchemes: ["clickhouse", "ch"], postConnectActions: [.selectDatabaseFromLastSession],
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
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: true,
                    supportsModifyPrimaryKey: false
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
                navigationModel: .standard,
                explainVariants: [
                    ExplainVariant(id: "explain", label: "EXPLAIN", sqlPrefix: "EXPLAIN"),
                ],
                pathFieldRole: .filePath,
                supportsHealthMonitor: false, urlSchemes: ["duckdb"], postConnectActions: [],
                brandColorHex: "#FFD900",
                queryLanguageName: "SQL", editorLanguage: .sql,
                connectionMode: .fileBased, supportsDatabaseSwitching: false,
                supportsColumnReorder: false,
                capabilities: PluginMetadataSnapshot.CapabilityFlags(
                    supportsSchemaSwitching: false,
                    supportsImport: true,
                    supportsExport: true,
                    supportsSSH: false,
                    supportsSSL: false,
                    supportsCascadeDrop: false,
                    supportsForeignKeyDisable: true,
                    supportsReadOnlyMode: true,
                    supportsQueryProgress: false,
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: false,
                    supportsRenameColumn: true
                ),
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
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: true,
                    supportsModifyColumn: false,
                    supportsAddIndex: false,
                    supportsDropIndex: false,
                    supportsModifyPrimaryKey: false
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
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: true,
                    supportsModifyColumn: false,
                    supportsAddIndex: false,
                    supportsDropIndex: false,
                    supportsModifyPrimaryKey: false
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
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: false
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
                    requiresReconnectForDatabaseSwitch: false,
                    supportsDropDatabase: true
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
            ))
        ] + cloudPluginDefaults()
    }
    // swiftlint:enable function_body_length
}
