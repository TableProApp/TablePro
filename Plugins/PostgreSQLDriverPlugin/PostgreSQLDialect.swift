import Foundation
import TableProPluginKit

enum PostgreSQLDialect {
    static let descriptor = SQLDialectDescriptor(
        identifierQuote: "\"",
        keywords: keywords,
        functions: functions,
        dataTypes: dataTypes,
        tableOptions: ["INHERITS", "PARTITION BY", "TABLESPACE", "WITH", "WITHOUT OIDS"],
        regexSyntax: .tilde,
        booleanLiteralStyle: .truefalse,
        likeEscapeStyle: .explicit,
        paginationStyle: .limit,
        caseSensitivityStyle: .ilikeOperator,
        operators: operators
    )

    static let keywords: Set<String> = reservedKeywords
        .union(nonReservedKeywords)
        .union(multiWordConstructs)

    private static let reservedKeywords: Set<String> = [
        "ALL", "ANALYSE", "ANALYZE", "AND", "ANY", "ARRAY", "AS", "ASC", "ASYMMETRIC", "BOTH",
        "CASE", "CAST", "CHECK", "COLLATE", "COLUMN", "CONSTRAINT", "CREATE", "CURRENT_CATALOG",
        "CURRENT_DATE", "CURRENT_ROLE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "CURRENT_USER",
        "DEFAULT", "DEFERRABLE", "DESC", "DISTINCT", "DO", "ELSE", "END", "EXCEPT", "FALSE",
        "FETCH", "FOR", "FOREIGN", "FROM", "GRANT", "GROUP", "HAVING", "IN", "INITIALLY",
        "INTERSECT", "INTO", "LATERAL", "LEADING", "LIMIT", "LOCALTIME", "LOCALTIMESTAMP",
        "NOT", "NULL", "OFFSET", "ON", "ONLY", "OR", "ORDER", "PLACING", "PRIMARY", "REFERENCES",
        "RETURNING", "SELECT", "SESSION_USER", "SOME", "SYMMETRIC", "SYSTEM_USER", "TABLE",
        "THEN", "TO", "TRAILING", "TRUE", "UNION", "UNIQUE", "USER", "USING", "VARIADIC",
        "WHEN", "WHERE", "WINDOW", "WITH",
        "AUTHORIZATION", "BINARY", "COLLATION", "CONCURRENTLY", "CROSS", "CURRENT_SCHEMA",
        "FREEZE", "FULL", "ILIKE", "INNER", "IS", "ISNULL", "JOIN", "LEFT", "LIKE", "NATURAL",
        "NOTNULL", "OUTER", "OVERLAPS", "RIGHT", "SIMILAR", "TABLESAMPLE", "VERBOSE"
    ]

    private static let nonReservedKeywords: Set<String> = [
        "ABORT", "ABSENT", "ABSOLUTE", "ACCESS", "ACTION", "ADD", "ADMIN", "AFTER", "AGGREGATE",
        "ALTER", "ALWAYS", "AT", "ATOMIC", "ATTACH", "ATTRIBUTE", "BACKWARD", "BEFORE", "BEGIN",
        "BREADTH", "BY", "CACHE", "CALL", "CALLED", "CASCADE", "CASCADED", "CHAIN",
        "CHARACTERISTICS", "CHECKPOINT", "CLASS", "CLOSE", "CLUSTER", "COLUMNS", "COMMENT",
        "COMMENTS", "COMMIT", "COMMITTED", "COMPRESSION", "CONDITIONAL", "CONFIGURATION",
        "CONFLICT", "CONNECTION", "CONSTRAINTS", "CONTENT", "CONTINUE", "CONVERSION", "COPY",
        "COST", "CSV", "CUBE", "CURRENT", "CURSOR", "CYCLE", "DATA", "DATABASE", "DAY",
        "DEALLOCATE", "DECLARE", "DEFAULTS", "DEFERRED", "DEFINER", "DELETE", "DELIMITER",
        "DELIMITERS", "DEPENDS", "DEPTH", "DETACH", "DICTIONARY", "DISABLE", "DISCARD",
        "DOCUMENT", "DOMAIN", "DOUBLE", "DROP", "EACH", "EMPTY", "ENABLE", "ENCODING",
        "ENCRYPTED", "ENUM", "ERROR", "ESCAPE", "EVENT", "EXCLUDE", "EXCLUDING", "EXCLUSIVE",
        "EXECUTE", "EXPLAIN", "EXPRESSION", "EXTENSION", "EXTERNAL", "FAMILY", "FILTER",
        "FINALIZE", "FIRST", "FOLLOWING", "FORCE", "FORMAT", "FORWARD", "FUNCTION", "FUNCTIONS",
        "GENERATED", "GLOBAL", "GRANTED", "GROUPS", "HANDLER", "HEADER", "HOLD", "HOUR",
        "IDENTITY", "IF", "IMMEDIATE", "IMMUTABLE", "IMPLICIT", "IMPORT", "INCLUDE", "INCLUDING",
        "INCREMENT", "INDENT", "INDEX", "INDEXES", "INHERIT", "INHERITS", "INPUT", "INSENSITIVE",
        "INSERT", "INSTEAD", "INVOKER", "ISOLATION", "KEEP", "KEY", "KEYS", "LABEL", "LANGUAGE",
        "LARGE", "LAST", "LEAKPROOF", "LEVEL", "LISTEN", "LOAD", "LOCAL", "LOCATION", "LOCK",
        "LOCKED", "LOGGED", "MAPPING", "MATCH", "MATCHED", "MATERIALIZED", "MAXVALUE", "MERGE",
        "METHOD", "MINUTE", "MINVALUE", "MODE", "MONTH", "MOVE", "NAME", "NAMES", "NESTED",
        "NEW", "NEXT", "NO", "NORMALIZED", "NOTHING", "NOTIFY", "NOWAIT", "NULLS", "OBJECT",
        "OF", "OFF", "OLD", "OMIT", "OPERATOR", "OPTION", "OPTIONS", "ORDINALITY", "OTHERS",
        "OVER", "OVERRIDING", "OWNED", "OWNER", "PARALLEL", "PARAMETER", "PARSER", "PARTIAL",
        "PARTITION", "PASSING", "PASSWORD", "PATH", "POLICY", "PRECEDING", "PREPARE", "PREPARED",
        "PRESERVE", "PRIOR", "PRIVILEGES", "PROCEDURE", "PROCEDURES", "PROGRAM", "PUBLICATION",
        "QUOTE", "QUOTES", "RANGE", "READ", "REASSIGN", "RECURSIVE", "REFERENCING", "REFRESH",
        "REINDEX", "RELATIVE", "RELEASE", "RENAME", "REPEATABLE", "REPLACE", "REPLICA", "RESET",
        "RESTART", "RESTRICT", "RETURN", "RETURNS", "REVOKE", "ROLE", "ROLLBACK", "ROLLUP",
        "ROUTINE", "ROUTINES", "ROWS", "RULE", "SAVEPOINT", "SCALAR", "SCHEMA", "SCHEMAS",
        "SCROLL", "SEARCH", "SECOND", "SECURITY", "SEQUENCE", "SEQUENCES", "SERIALIZABLE",
        "SERVER", "SESSION", "SET", "SETS", "SHARE", "SHOW", "SIMPLE", "SKIP", "SNAPSHOT",
        "SOURCE", "SQL", "STABLE", "STANDALONE", "START", "STATEMENT", "STATISTICS", "STDIN",
        "STDOUT", "STORAGE", "STORED", "STRICT", "STRING", "STRIP", "SUBSCRIPTION", "SUPPORT",
        "SYSTEM", "TABLES", "TABLESPACE", "TARGET", "TEMP", "TEMPLATE", "TEMPORARY", "TEXT",
        "TIES", "TRANSACTION", "TRANSFORM", "TRIGGER", "TRUNCATE", "TRUSTED", "TYPE", "TYPES",
        "UNBOUNDED", "UNCOMMITTED", "UNCONDITIONAL", "UNENCRYPTED", "UNKNOWN", "UNLISTEN",
        "UNLOGGED", "UNTIL", "UPDATE", "VACUUM", "VALID", "VALIDATE", "VALIDATOR", "VALUE",
        "VARYING", "VERSION", "VIEW", "VIEWS", "VOLATILE", "WHITESPACE", "WITHIN", "WITHOUT",
        "WORK", "WRAPPER", "WRITE", "XML", "YEAR", "YES", "ZONE",
        "BETWEEN", "COALESCE", "EXISTS", "GREATEST", "GROUPING", "LEAST", "MERGE_ACTION",
        "NULLIF", "OVERLAY", "POSITION", "SETOF", "SUBSTRING", "TREAT", "TRIM", "VALUES"
    ]

    private static let multiWordConstructs: Set<String> = [
        "ON CONFLICT", "ON CONFLICT DO NOTHING", "ON CONFLICT DO UPDATE SET", "ON CONSTRAINT",
        "DO NOTHING", "DO UPDATE SET", "DEFAULT VALUES", "OVERRIDING SYSTEM VALUE",
        "OVERRIDING USER VALUE", "RETURNING *",
        "SELECT DISTINCT", "SELECT DISTINCT ON", "DISTINCT ON", "GROUP BY", "GROUP BY ALL",
        "GROUP BY DISTINCT", "GROUPING SETS", "ORDER BY", "NULLS FIRST", "NULLS LAST",
        "UNION ALL", "UNION DISTINCT", "INTERSECT ALL", "EXCEPT ALL", "LIMIT ALL",
        "FETCH FIRST", "FETCH NEXT", "WITH TIES", "FOR UPDATE", "FOR NO KEY UPDATE",
        "FOR SHARE", "FOR KEY SHARE", "SKIP LOCKED", "TABLESAMPLE SYSTEM",
        "TABLESAMPLE BERNOULLI", "WITH ORDINALITY", "ROWS FROM",
        "INNER JOIN", "LEFT JOIN", "LEFT OUTER JOIN", "RIGHT JOIN", "RIGHT OUTER JOIN",
        "FULL JOIN", "FULL OUTER JOIN", "CROSS JOIN", "NATURAL JOIN",
        "WITH RECURSIVE", "AS MATERIALIZED", "AS NOT MATERIALIZED",
        "SEARCH BREADTH FIRST BY", "SEARCH DEPTH FIRST BY",
        "CREATE TABLE IF NOT EXISTS", "CREATE TEMP TABLE", "CREATE UNLOGGED TABLE",
        "NOT NULL", "PRIMARY KEY", "FOREIGN KEY", "UNIQUE NULLS DISTINCT",
        "UNIQUE NULLS NOT DISTINCT", "GENERATED ALWAYS AS", "GENERATED ALWAYS AS IDENTITY",
        "GENERATED BY DEFAULT AS IDENTITY", "MATCH FULL", "MATCH PARTIAL", "MATCH SIMPLE",
        "ON DELETE CASCADE", "ON DELETE RESTRICT", "ON DELETE SET NULL", "ON DELETE NO ACTION",
        "ON UPDATE CASCADE", "ON UPDATE RESTRICT", "ON UPDATE SET NULL",
        "DEFERRABLE INITIALLY DEFERRED", "INITIALLY IMMEDIATE", "EXCLUDE USING",
        "PARTITION BY RANGE", "PARTITION BY LIST", "PARTITION BY HASH", "PARTITION OF",
        "FOR VALUES IN", "FOR VALUES FROM", "FOR VALUES WITH",
        "ON COMMIT PRESERVE ROWS", "ON COMMIT DELETE ROWS", "ON COMMIT DROP",
        "OVER", "PARTITION BY", "FILTER", "WITHIN GROUP", "ROWS BETWEEN", "RANGE BETWEEN",
        "GROUPS BETWEEN", "UNBOUNDED PRECEDING", "UNBOUNDED FOLLOWING", "CURRENT ROW",
        "EXCLUDE CURRENT ROW", "EXCLUDE GROUP", "EXCLUDE TIES", "EXCLUDE NO OTHERS",
        "MERGE INTO", "WHEN MATCHED THEN", "WHEN MATCHED THEN UPDATE SET",
        "WHEN MATCHED THEN DELETE", "WHEN NOT MATCHED THEN INSERT",
        "WHEN NOT MATCHED BY TARGET THEN", "WHEN NOT MATCHED BY SOURCE THEN",
        "CREATE INDEX CONCURRENTLY", "CREATE MATERIALIZED VIEW", "REFRESH MATERIALIZED VIEW",
        "CREATE TYPE", "CREATE EXTENSION", "IF NOT EXISTS", "IF EXISTS", "CASCADE", "RESTRICT",
        "IS NULL", "IS NOT NULL", "IS TRUE", "IS NOT TRUE", "IS FALSE", "IS NOT FALSE",
        "IS UNKNOWN", "IS NOT UNKNOWN", "IS DISTINCT FROM", "IS NOT DISTINCT FROM",
        "BETWEEN SYMMETRIC", "NOT BETWEEN", "NOT BETWEEN SYMMETRIC", "NOT LIKE", "NOT ILIKE",
        "SIMILAR TO", "NOT SIMILAR TO", "AT TIME ZONE", "AT LOCAL"
    ]

    static let functions: Set<String> = aggregateFunctions
        .union(windowFunctions)
        .union(stringFunctions)
        .union(mathFunctions)
        .union(dateTimeFunctions)
        .union(jsonFunctions)
        .union(arrayFunctions)
        .union(rangeFunctions)
        .union(conditionalFunctions)
        .union(fullTextFunctions)
        .union(uuidFunctions)
        .union(systemFunctions)
        .union(xmlFunctions)

    private static let aggregateFunctions: Set<String> = [
        "ANY_VALUE", "ARRAY_AGG", "AVG", "BIT_AND", "BIT_OR", "BIT_XOR", "BOOL_AND", "BOOL_OR",
        "COUNT", "EVERY", "JSON_AGG", "JSONB_AGG", "JSON_AGG_STRICT", "JSONB_AGG_STRICT",
        "JSON_ARRAYAGG", "JSON_OBJECTAGG", "JSON_OBJECT_AGG", "JSONB_OBJECT_AGG",
        "JSON_OBJECT_AGG_STRICT", "JSONB_OBJECT_AGG_STRICT", "JSON_OBJECT_AGG_UNIQUE",
        "JSONB_OBJECT_AGG_UNIQUE", "MAX", "MIN", "RANGE_AGG", "RANGE_INTERSECT_AGG",
        "STRING_AGG", "SUM", "XMLAGG", "GROUPING",
        "CORR", "COVAR_POP", "COVAR_SAMP", "REGR_AVGX", "REGR_AVGY", "REGR_COUNT",
        "REGR_INTERCEPT", "REGR_R2", "REGR_SLOPE", "REGR_SXX", "REGR_SXY", "REGR_SYY",
        "STDDEV", "STDDEV_POP", "STDDEV_SAMP", "VARIANCE", "VAR_POP", "VAR_SAMP",
        "MODE", "PERCENTILE_CONT", "PERCENTILE_DISC"
    ]

    private static let windowFunctions: Set<String> = [
        "ROW_NUMBER", "RANK", "DENSE_RANK", "PERCENT_RANK", "CUME_DIST", "NTILE",
        "LAG", "LEAD", "FIRST_VALUE", "LAST_VALUE", "NTH_VALUE"
    ]

    private static let stringFunctions: Set<String> = [
        "ASCII", "BIT_LENGTH", "BTRIM", "CHAR_LENGTH", "CHARACTER_LENGTH", "CHR", "CONCAT",
        "CONCAT_WS", "FORMAT", "INITCAP", "LEFT", "LENGTH", "LOWER", "LPAD", "LTRIM", "MD5",
        "NORMALIZE", "OCTET_LENGTH", "OVERLAY", "PARSE_IDENT", "PG_CLIENT_ENCODING", "POSITION",
        "QUOTE_IDENT", "QUOTE_LITERAL", "QUOTE_NULLABLE", "REGEXP_COUNT", "REGEXP_INSTR",
        "REGEXP_LIKE", "REGEXP_MATCH", "REGEXP_MATCHES", "REGEXP_REPLACE",
        "REGEXP_SPLIT_TO_ARRAY", "REGEXP_SPLIT_TO_TABLE", "REGEXP_SUBSTR", "REPEAT", "REPLACE",
        "REVERSE", "RIGHT", "RPAD", "RTRIM", "SPLIT_PART", "STARTS_WITH", "STRING_TO_ARRAY",
        "STRING_TO_TABLE", "STRPOS", "SUBSTR", "SUBSTRING", "TO_ASCII", "TO_BIN", "TO_HEX",
        "TO_OCT", "TRANSLATE", "TRIM", "UNISTR", "UNICODE_ASSIGNED", "UPPER",
        "TO_CHAR", "TO_DATE", "TO_NUMBER", "TO_TIMESTAMP",
        "CONVERT", "CONVERT_FROM", "CONVERT_TO", "DECODE", "ENCODE", "GET_BIT", "GET_BYTE",
        "SET_BIT", "SET_BYTE", "BIT_COUNT", "SHA224", "SHA256", "SHA384", "SHA512"
    ]

    private static let mathFunctions: Set<String> = [
        "ABS", "CBRT", "CEIL", "CEILING", "DEGREES", "DIV", "EXP", "FACTORIAL", "FLOOR", "GCD",
        "LCM", "LN", "LOG", "LOG10", "MIN_SCALE", "MOD", "PI", "POWER", "RADIANS", "RANDOM",
        "RANDOM_NORMAL", "ROUND", "SCALE", "SETSEED", "SIGN", "SQRT", "TRIM_SCALE", "TRUNC",
        "WIDTH_BUCKET", "ERF", "ERFC",
        "ACOS", "ASIN", "ATAN", "ATAN2", "COS", "COT", "SIN", "TAN",
        "ACOSD", "ASIND", "ATAND", "ATAN2D", "COSD", "COTD", "SIND", "TAND",
        "SINH", "COSH", "TANH", "ASINH", "ACOSH", "ATANH"
    ]

    private static let dateTimeFunctions: Set<String> = [
        "AGE", "CLOCK_TIMESTAMP", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP",
        "DATE_ADD", "DATE_BIN", "DATE_PART", "DATE_SUBTRACT", "DATE_TRUNC", "EXTRACT",
        "ISFINITE", "JUSTIFY_DAYS", "JUSTIFY_HOURS", "JUSTIFY_INTERVAL", "LOCALTIME",
        "LOCALTIMESTAMP", "MAKE_DATE", "MAKE_INTERVAL", "MAKE_TIME", "MAKE_TIMESTAMP",
        "MAKE_TIMESTAMPTZ", "NOW", "PG_SLEEP", "PG_SLEEP_FOR", "PG_SLEEP_UNTIL",
        "STATEMENT_TIMESTAMP", "TIMEOFDAY", "TRANSACTION_TIMESTAMP"
    ]

    private static let jsonFunctions: Set<String> = [
        "TO_JSON", "TO_JSONB", "ARRAY_TO_JSON", "ROW_TO_JSON", "JSON_BUILD_ARRAY",
        "JSONB_BUILD_ARRAY", "JSON_BUILD_OBJECT", "JSONB_BUILD_OBJECT", "JSON_OBJECT",
        "JSONB_OBJECT", "JSON_ARRAY", "JSON_SCALAR", "JSON_SERIALIZE",
        "JSON_ARRAY_ELEMENTS", "JSONB_ARRAY_ELEMENTS", "JSON_ARRAY_ELEMENTS_TEXT",
        "JSONB_ARRAY_ELEMENTS_TEXT", "JSON_ARRAY_LENGTH", "JSONB_ARRAY_LENGTH", "JSON_EACH",
        "JSONB_EACH", "JSON_EACH_TEXT", "JSONB_EACH_TEXT", "JSON_EXTRACT_PATH",
        "JSONB_EXTRACT_PATH", "JSON_EXTRACT_PATH_TEXT", "JSONB_EXTRACT_PATH_TEXT",
        "JSON_OBJECT_KEYS", "JSONB_OBJECT_KEYS", "JSON_POPULATE_RECORD",
        "JSONB_POPULATE_RECORD", "JSON_POPULATE_RECORDSET", "JSONB_POPULATE_RECORDSET",
        "JSONB_POPULATE_RECORD_VALID", "JSON_TO_RECORD", "JSONB_TO_RECORD",
        "JSON_TO_RECORDSET", "JSONB_TO_RECORDSET", "JSONB_SET", "JSONB_SET_LAX",
        "JSONB_INSERT", "JSONB_PRETTY", "JSON_STRIP_NULLS", "JSONB_STRIP_NULLS", "JSON_TYPEOF",
        "JSONB_TYPEOF", "JSONB_PATH_EXISTS", "JSONB_PATH_MATCH", "JSONB_PATH_QUERY",
        "JSONB_PATH_QUERY_ARRAY", "JSONB_PATH_QUERY_FIRST", "JSONB_PATH_EXISTS_TZ",
        "JSONB_PATH_MATCH_TZ", "JSONB_PATH_QUERY_TZ", "JSONB_PATH_QUERY_ARRAY_TZ",
        "JSONB_PATH_QUERY_FIRST_TZ",
        "JSON_EXISTS", "JSON_QUERY", "JSON_VALUE", "JSON_TABLE"
    ]

    private static let arrayFunctions: Set<String> = [
        "ARRAY_APPEND", "ARRAY_CAT", "ARRAY_DIMS", "ARRAY_FILL", "ARRAY_LENGTH", "ARRAY_LOWER",
        "ARRAY_NDIMS", "ARRAY_POSITION", "ARRAY_POSITIONS", "ARRAY_PREPEND", "ARRAY_REMOVE",
        "ARRAY_REPLACE", "ARRAY_SAMPLE", "ARRAY_SHUFFLE", "ARRAY_TO_STRING", "ARRAY_UPPER",
        "CARDINALITY", "TRIM_ARRAY", "UNNEST", "GENERATE_SERIES", "GENERATE_SUBSCRIPTS"
    ]

    private static let rangeFunctions: Set<String> = [
        "LOWER", "UPPER", "ISEMPTY", "LOWER_INC", "UPPER_INC", "LOWER_INF", "UPPER_INF",
        "RANGE_MERGE", "MULTIRANGE"
    ]

    private static let conditionalFunctions: Set<String> = [
        "COALESCE", "NULLIF", "GREATEST", "LEAST", "NUM_NONNULLS", "NUM_NULLS"
    ]

    private static let fullTextFunctions: Set<String> = [
        "TO_TSVECTOR", "JSON_TO_TSVECTOR", "JSONB_TO_TSVECTOR", "TO_TSQUERY", "PLAINTO_TSQUERY",
        "PHRASETO_TSQUERY", "WEBSEARCH_TO_TSQUERY", "SETWEIGHT", "STRIP", "NUMNODE", "QUERYTREE",
        "TS_RANK", "TS_RANK_CD", "TS_HEADLINE", "TS_DELETE", "TS_FILTER", "TSQUERY_PHRASE",
        "TS_REWRITE", "TSVECTOR_TO_ARRAY", "ARRAY_TO_TSVECTOR", "GET_CURRENT_TS_CONFIG",
        "TS_DEBUG", "TS_LEXIZE", "TS_PARSE", "TS_TOKEN_TYPE", "TS_STAT"
    ]

    private static let uuidFunctions: Set<String> = [
        "GEN_RANDOM_UUID", "UUID_EXTRACT_TIMESTAMP", "UUID_EXTRACT_VERSION"
    ]

    private static let systemFunctions: Set<String> = [
        "CURRENT_CATALOG", "CURRENT_DATABASE", "CURRENT_QUERY", "CURRENT_ROLE", "CURRENT_SCHEMA",
        "CURRENT_SCHEMAS", "CURRENT_USER", "SESSION_USER", "SYSTEM_USER", "VERSION",
        "PG_BACKEND_PID", "PG_BLOCKING_PIDS", "PG_TYPEOF", "FORMAT_TYPE", "PG_COLLATION_FOR",
        "PG_BASETYPE", "PG_GET_CONSTRAINTDEF", "PG_GET_EXPR", "PG_GET_FUNCTIONDEF",
        "PG_GET_INDEXDEF", "PG_GET_RULEDEF", "PG_GET_SERIAL_SEQUENCE", "PG_GET_TRIGGERDEF",
        "PG_GET_USERBYID", "PG_GET_VIEWDEF", "PG_GET_KEYWORDS", "OBJ_DESCRIPTION",
        "COL_DESCRIPTION", "SHOBJ_DESCRIPTION", "PG_INPUT_IS_VALID", "PG_INPUT_ERROR_INFO",
        "PG_COLUMN_SIZE", "PG_COLUMN_COMPRESSION", "PG_DATABASE_SIZE", "PG_INDEXES_SIZE",
        "PG_RELATION_SIZE", "PG_SIZE_BYTES", "PG_SIZE_PRETTY", "PG_TABLE_SIZE",
        "PG_TABLESPACE_SIZE", "PG_TOTAL_RELATION_SIZE", "PG_RELATION_FILENODE",
        "PG_RELATION_FILEPATH", "CURRENT_SETTING", "SET_CONFIG", "PG_CANCEL_BACKEND",
        "PG_TERMINATE_BACKEND", "PG_RELOAD_CONF", "PG_NOTIFY", "PG_ADVISORY_LOCK",
        "PG_ADVISORY_UNLOCK", "PG_ADVISORY_XACT_LOCK", "PG_TRY_ADVISORY_LOCK",
        "PG_TRY_ADVISORY_XACT_LOCK", "HAS_TABLE_PRIVILEGE", "HAS_COLUMN_PRIVILEGE",
        "HAS_DATABASE_PRIVILEGE", "HAS_SCHEMA_PRIVILEGE", "HAS_SEQUENCE_PRIVILEGE",
        "HAS_FUNCTION_PRIVILEGE", "PG_HAS_ROLE", "ROW_SECURITY_ACTIVE", "TO_REGCLASS",
        "TO_REGTYPE", "TO_REGPROC", "TO_REGNAMESPACE", "TO_REGROLE",
        "NEXTVAL", "CURRVAL", "LASTVAL", "SETVAL"
    ]

    private static let xmlFunctions: Set<String> = [
        "XMLCOMMENT", "XMLCONCAT", "XMLELEMENT", "XMLFOREST", "XMLPI", "XMLROOT", "XMLTEXT",
        "XMLEXISTS", "XML_IS_WELL_FORMED", "XML_IS_WELL_FORMED_DOCUMENT",
        "XML_IS_WELL_FORMED_CONTENT", "XPATH", "XPATH_EXISTS", "XMLTABLE", "TABLE_TO_XML",
        "QUERY_TO_XML", "CURSOR_TO_XML", "SCHEMA_TO_XML", "DATABASE_TO_XML"
    ]

    static let dataTypes: Set<String> = [
        "SMALLINT", "INT2", "INTEGER", "INT", "INT4", "BIGINT", "INT8", "DECIMAL", "NUMERIC",
        "REAL", "FLOAT4", "DOUBLE PRECISION", "FLOAT", "FLOAT8", "MONEY",
        "SMALLSERIAL", "SERIAL2", "SERIAL", "SERIAL4", "BIGSERIAL", "SERIAL8",
        "CHARACTER VARYING", "VARCHAR", "CHARACTER", "CHAR", "BPCHAR", "TEXT", "NAME", "BYTEA",
        "TIMESTAMP", "TIMESTAMP WITHOUT TIME ZONE", "TIMESTAMP WITH TIME ZONE", "TIMESTAMPTZ",
        "DATE", "TIME", "TIME WITHOUT TIME ZONE", "TIME WITH TIME ZONE", "TIMETZ", "INTERVAL",
        "BOOLEAN", "BOOL",
        "POINT", "LINE", "LSEG", "BOX", "PATH", "POLYGON", "CIRCLE",
        "CIDR", "INET", "MACADDR", "MACADDR8",
        "BIT", "BIT VARYING", "VARBIT", "TSVECTOR", "TSQUERY", "UUID", "XML",
        "JSON", "JSONB", "JSONPATH",
        "INT4RANGE", "INT8RANGE", "NUMRANGE", "TSRANGE", "TSTZRANGE", "DATERANGE",
        "INT4MULTIRANGE", "INT8MULTIRANGE", "NUMMULTIRANGE", "TSMULTIRANGE", "TSTZMULTIRANGE",
        "DATEMULTIRANGE",
        "OID", "REGCLASS", "REGCOLLATION", "REGCONFIG", "REGDICTIONARY", "REGNAMESPACE",
        "REGOPER", "REGOPERATOR", "REGPROC", "REGPROCEDURE", "REGROLE", "REGTYPE",
        "PG_LSN", "PG_SNAPSHOT", "ARRAY", "RECORD"
    ]

    static let operators: [SQLOperatorDescriptor] = castOperators
        + comparisonOperators
        + patternOperators
        + jsonOperators
        + arrayOperators
        + rangeOperators
        + fullTextOperators
        + networkOperators
        + mathOperators

    private static let castOperators: [SQLOperatorDescriptor] = [
        .init(symbol: "::", summary: "Typecast", category: .cast)
    ]

    private static let comparisonOperators: [SQLOperatorDescriptor] = [
        .init(symbol: "=", summary: "Equal", category: .comparison),
        .init(symbol: "<>", summary: "Not equal", category: .comparison),
        .init(symbol: "!=", summary: "Not equal", category: .comparison),
        .init(symbol: "<", summary: "Less than", category: .comparison),
        .init(symbol: ">", summary: "Greater than", category: .comparison),
        .init(symbol: "<=", summary: "Less than or equal to", category: .comparison),
        .init(symbol: ">=", summary: "Greater than or equal to", category: .comparison),
        .init(symbol: "IS DISTINCT FROM", summary: "Not equal, treating null as comparable",
              category: .predicate),
        .init(symbol: "IS NOT DISTINCT FROM", summary: "Equal, treating null as comparable",
              category: .predicate),
        .init(symbol: "IS NULL", summary: "Test whether value is null", category: .predicate,
              placement: .postfix),
        .init(symbol: "IS NOT NULL", summary: "Test whether value is not null",
              category: .predicate, placement: .postfix),
        .init(symbol: "BETWEEN SYMMETRIC",
              summary: "Between, after sorting the two endpoint values", category: .predicate)
    ]

    private static let patternOperators: [SQLOperatorDescriptor] = [
        .init(symbol: "||", summary: "Concatenates the two strings", category: .string,
              appliesToTypes: ["text"]),
        .init(symbol: "^@", summary: "True if the first string starts with the second",
              category: .string, appliesToTypes: ["text"]),
        .init(symbol: "~", summary: "Matches POSIX regular expression, case sensitive",
              category: .pattern, appliesToTypes: ["text"]),
        .init(symbol: "~*", summary: "Matches POSIX regular expression, case insensitive",
              category: .pattern, appliesToTypes: ["text"]),
        .init(symbol: "!~", summary: "Does not match POSIX regular expression, case sensitive",
              category: .pattern, appliesToTypes: ["text"]),
        .init(symbol: "!~*",
              summary: "Does not match POSIX regular expression, case insensitive",
              category: .pattern, appliesToTypes: ["text"]),
        .init(symbol: "~~", summary: "Equivalent to LIKE", category: .pattern,
              appliesToTypes: ["text"]),
        .init(symbol: "~~*", summary: "Equivalent to ILIKE", category: .pattern,
              appliesToTypes: ["text"]),
        .init(symbol: "!~~", summary: "Equivalent to NOT LIKE", category: .pattern,
              appliesToTypes: ["text"]),
        .init(symbol: "!~~*", summary: "Equivalent to NOT ILIKE", category: .pattern,
              appliesToTypes: ["text"])
    ]

    private static let jsonOperators: [SQLOperatorDescriptor] = [
        .init(symbol: "->", summary: "Extracts JSON object field or array element, as json",
              category: .json, appliesToTypes: ["json", "jsonb"]),
        .init(symbol: "->>", summary: "Extracts JSON object field or array element, as text",
              category: .json, appliesToTypes: ["json", "jsonb"]),
        .init(symbol: "#>", summary: "Extracts JSON sub-object at the specified path",
              category: .json, appliesToTypes: ["json", "jsonb"]),
        .init(symbol: "#>>", summary: "Extracts JSON sub-object at the specified path, as text",
              category: .json, appliesToTypes: ["json", "jsonb"]),
        .init(symbol: "@>", summary: "Does the first JSON value contain the second?",
              category: .json, appliesToTypes: ["jsonb"]),
        .init(symbol: "<@", summary: "Is the first JSON value contained in the second?",
              category: .json, appliesToTypes: ["jsonb"]),
        .init(symbol: "?", summary: "Does the string exist as a top-level key or array element?",
              category: .json, appliesToTypes: ["jsonb"]),
        .init(symbol: "?|", summary: "Do any of the strings exist as top-level keys?",
              category: .json, appliesToTypes: ["jsonb"]),
        .init(symbol: "?&", summary: "Do all of the strings exist as top-level keys?",
              category: .json, appliesToTypes: ["jsonb"]),
        .init(symbol: "#-", summary: "Deletes the field or array element at the specified path",
              category: .json, appliesToTypes: ["jsonb"]),
        .init(symbol: "@?", summary: "Does the JSON path return any item?", category: .json,
              appliesToTypes: ["jsonb"]),
        .init(symbol: "@@", summary: "Returns the result of a JSON path predicate check",
              category: .json, appliesToTypes: ["jsonb"])
    ]

    private static let arrayOperators: [SQLOperatorDescriptor] = [
        .init(symbol: "@>", summary: "Does the first array contain the second?",
              category: .array, appliesToTypes: ["anyarray"]),
        .init(symbol: "<@", summary: "Is the first array contained by the second?",
              category: .array, appliesToTypes: ["anyarray"]),
        .init(symbol: "&&", summary: "Do the arrays overlap?", category: .array,
              appliesToTypes: ["anyarray"])
    ]

    private static let rangeOperators: [SQLOperatorDescriptor] = [
        .init(symbol: "<<", summary: "Is the first range strictly left of the second?",
              category: .range, appliesToTypes: ["anyrange"]),
        .init(symbol: ">>", summary: "Is the first range strictly right of the second?",
              category: .range, appliesToTypes: ["anyrange"]),
        .init(symbol: "&<", summary: "Does the first range not extend to the right of the second?",
              category: .range, appliesToTypes: ["anyrange"]),
        .init(symbol: "&>", summary: "Does the first range not extend to the left of the second?",
              category: .range, appliesToTypes: ["anyrange"]),
        .init(symbol: "-|-", summary: "Are the ranges adjacent?", category: .range,
              appliesToTypes: ["anyrange"])
    ]

    private static let fullTextOperators: [SQLOperatorDescriptor] = [
        .init(symbol: "@@", summary: "Does the tsvector match the tsquery?", category: .fullText,
              appliesToTypes: ["tsvector", "tsquery"]),
        .init(symbol: "<->", summary: "Constructs a phrase query for successive lexemes",
              category: .fullText, appliesToTypes: ["tsquery"]),
        .init(symbol: "!!", summary: "Negates a tsquery", category: .fullText,
              placement: .prefix, appliesToTypes: ["tsquery"])
    ]

    private static let networkOperators: [SQLOperatorDescriptor] = [
        .init(symbol: "<<=", summary: "Is subnet contained by or equal to subnet?",
              category: .network, appliesToTypes: ["inet", "cidr"]),
        .init(symbol: ">>=", summary: "Does subnet contain or equal subnet?", category: .network,
              appliesToTypes: ["inet", "cidr"])
    ]

    private static let mathOperators: [SQLOperatorDescriptor] = [
        .init(symbol: "^", summary: "Exponentiation", category: .math),
        .init(symbol: "|/", summary: "Square root", category: .math, placement: .prefix),
        .init(symbol: "||/", summary: "Cube root", category: .math, placement: .prefix),
        .init(symbol: "%", summary: "Modulo", category: .math),
        .init(symbol: "#", summary: "Bitwise exclusive OR", category: .bitwise),
        .init(symbol: "&", summary: "Bitwise AND", category: .bitwise),
        .init(symbol: "|", summary: "Bitwise OR", category: .bitwise)
    ]
}
