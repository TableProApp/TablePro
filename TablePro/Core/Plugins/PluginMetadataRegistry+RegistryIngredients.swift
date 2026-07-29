//
//  PluginMetadataRegistry+RegistryIngredients.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PluginMetadataRegistry {
    // swiftlint:disable function_body_length large_tuple
    func registryDefaultIngredients() -> (
        clickhouseDialect: SQLDialectDescriptor,
        clickhouseColumnTypes: [String: [String]],
        mssqlDialect: SQLDialectDescriptor,
        mssqlColumnTypes: [String: [String]],
        oracleDialect: SQLDialectDescriptor,
        oracleColumnTypes: [String: [String]],
        duckdbDialect: SQLDialectDescriptor,
        duckdbColumnTypes: [String: [String]],
        cassandraDialect: SQLDialectDescriptor,
        cassandraColumnTypes: [String: [String]],
        mongoCompletions: [CompletionEntry],
        mongoColumnTypes: [String: [String]],
        etcdCompletions: [CompletionEntry],
        redisCompletions: [CompletionEntry],
        redisColumnTypes: [String: [String]],
        d1Dialect: SQLDialectDescriptor,
        d1ColumnTypes: [String: [String]]
    ) {
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
        return (
            clickhouseDialect, clickhouseColumnTypes, mssqlDialect, mssqlColumnTypes,
            oracleDialect, oracleColumnTypes, duckdbDialect, duckdbColumnTypes,
            cassandraDialect, cassandraColumnTypes, mongoCompletions, mongoColumnTypes,
            etcdCompletions, redisCompletions, redisColumnTypes, d1Dialect, d1ColumnTypes
        )
    }
    // swiftlint:enable function_body_length large_tuple
}
