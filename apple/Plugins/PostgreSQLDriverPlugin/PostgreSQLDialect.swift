import Foundation
import TableProPluginKit
import TableProSQLVocabulary

enum PostgreSQLDialect {
    static let descriptor = SQLDialectDescriptor(
        identifierQuote: "\"",
        keywords: keywords,
        functions: SQLEngineVocabulary.postgreSQL.functions,
        dataTypes: SQLEngineVocabulary.postgreSQL.dataTypes,
        tableOptions: SQLEngineVocabulary.postgreSQL.tableOptions,
        regexSyntax: .tilde,
        booleanLiteralStyle: .truefalse,
        likeEscapeStyle: .explicit,
        paginationStyle: .limit,
        caseSensitivityStyle: .ilikeOperator,
        operators: SQLEngineVocabulary.postgreSQL.operators.compactMap(SQLOperatorDescriptor.init(vocabulary:)),
        textCastTypeName: "TEXT",
        functionNamesAreCaseInsensitive: SQLEngineVocabulary.postgreSQL.functionNamesAreCaseInsensitive,
        typeNamesAreCaseInsensitive: true
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
}

private extension SQLOperatorDescriptor {
    init?(vocabulary entry: SQLEngineVocabulary.Operator) {
        guard let category = Category(rawValue: entry.category),
              let placement = Placement(rawValue: entry.placement) else { return nil }
        self.init(
            symbol: entry.symbol,
            summary: entry.summary,
            category: category,
            placement: placement,
            appliesToTypes: entry.appliesToTypes
        )
    }
}
