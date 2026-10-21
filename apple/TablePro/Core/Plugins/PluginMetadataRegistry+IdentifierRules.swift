import Foundation
import TableProAutocomplete

// A reserved word, or a name a bare spelling reads as a built-in value, stays quoted even in the folded case.
extension SQLIdentifierRules {
    // PostgreSQL 17 reference, Appendix C: the reserved and "reserved (can be function or type)" key words.
    static let postgreSQL = SQLIdentifierRules(folding: .lower, reservedWords: [
        "ALL", "ANALYSE", "ANALYZE", "AND", "ANY", "ARRAY", "AS", "ASC", "ASYMMETRIC", "BOTH", "CASE", "CAST",
        "CHECK", "COLLATE", "COLUMN", "CONSTRAINT", "CREATE", "CURRENT_CATALOG", "CURRENT_DATE", "CURRENT_ROLE",
        "CURRENT_TIME", "CURRENT_TIMESTAMP", "CURRENT_USER", "DEFAULT", "DEFERRABLE", "DESC", "DISTINCT", "DO",
        "ELSE", "END", "EXCEPT", "FALSE", "FETCH", "FOR", "FOREIGN", "FROM", "GRANT", "GROUP", "HAVING", "IN",
        "INITIALLY", "INTERSECT", "INTO", "LATERAL", "LEADING", "LIMIT", "LOCALTIME", "LOCALTIMESTAMP", "NOT",
        "NULL", "OFFSET", "ON", "ONLY", "OR", "ORDER", "PLACING", "PRIMARY", "REFERENCES", "RETURNING", "SELECT",
        "SESSION_USER", "SOME", "SYMMETRIC", "SYSTEM_USER", "TABLE", "THEN", "TO", "TRAILING", "TRUE", "UNION",
        "UNIQUE", "USER", "USING", "VARIADIC", "WHEN", "WHERE", "WINDOW", "WITH",
        "AUTHORIZATION", "BINARY", "COLLATION", "CONCURRENTLY", "CROSS", "CURRENT_SCHEMA", "FREEZE", "FULL",
        "ILIKE", "INNER", "IS", "ISNULL", "JOIN", "LEFT", "LIKE", "NATURAL", "NOTNULL", "OUTER", "OVERLAPS",
        "RIGHT", "SIMILAR", "TABLESAMPLE", "VERBOSE",
    ])

    // Oracle Database SQL Language Reference: Oracle SQL Reserved Words, then the pseudocolumns and the functions
    // called without parentheses, which a bare column of that name reads as instead.
    static let oracle = SQLIdentifierRules(folding: .upper, reservedWords: [
        "ACCESS", "ADD", "ALL", "ALTER", "AND", "ANY", "AS", "ASC", "AUDIT", "BETWEEN", "BY", "CHAR", "CHECK",
        "CLUSTER", "COLUMN", "COLUMN_VALUE", "COMMENT", "COMPRESS", "CONNECT", "CREATE", "CURRENT", "DATE",
        "DECIMAL", "DEFAULT", "DELETE", "DESC", "DISTINCT", "DROP", "ELSE", "EXCLUSIVE", "EXISTS", "FILE", "FLOAT",
        "FOR", "FROM", "GRANT", "GROUP", "HAVING", "IDENTIFIED", "IMMEDIATE", "IN", "INCREMENT", "INDEX", "INITIAL",
        "INSERT", "INTEGER", "INTERSECT", "INTO", "IS", "LEVEL", "LIKE", "LOCK", "LONG", "MAXEXTENTS", "MINUS",
        "MLSLABEL", "MODE", "MODIFY", "NESTED_TABLE_ID", "NOAUDIT", "NOCOMPRESS", "NOT", "NOWAIT", "NULL", "NUMBER",
        "OF", "OFFLINE", "ON", "ONLINE", "OPTION", "OR", "ORDER", "PCTFREE", "PRIOR", "PUBLIC", "RAW", "RENAME",
        "RESOURCE", "REVOKE", "ROW", "ROWID", "ROWNUM", "ROWS", "SELECT", "SESSION", "SET", "SHARE", "SIZE",
        "SMALLINT", "START", "SUCCESSFUL", "SYNONYM", "SYSDATE", "TABLE", "THEN", "TO", "TRIGGER", "UID", "UNION",
        "UNIQUE", "UPDATE", "USER", "VALIDATE", "VALUES", "VARCHAR", "VARCHAR2", "VIEW", "WHENEVER", "WHERE", "WITH",
        "CONNECT_BY_ISCYCLE", "CONNECT_BY_ISLEAF", "CURRVAL", "NEXTVAL", "OBJECT_ID", "OBJECT_VALUE", "ORA_ROWSCN",
        "XMLDATA", "CURRENT_DATE", "CURRENT_TIMESTAMP", "DBTIMEZONE", "LOCALTIMESTAMP", "SESSIONTIMEZONE",
        "SYSTIMESTAMP",
    ])

    // Snowflake SQL reference, Reserved & limited keywords.
    static let snowflake = SQLIdentifierRules(folding: .upper, reservedWords: [
        "ACCOUNT", "ALL", "ALTER", "AND", "ANY", "AS", "BETWEEN", "BY", "CASE", "CAST", "CHECK", "COLUMN", "CONNECT",
        "CONNECTION", "CONSTRAINT", "CREATE", "CROSS", "CURRENT", "CURRENT_DATE", "CURRENT_TIME",
        "CURRENT_TIMESTAMP", "CURRENT_USER", "DATABASE", "DELETE", "DISTINCT", "DROP", "ELSE", "EXISTS", "FALSE",
        "FOLLOWING", "FOR", "FROM", "FULL", "GRANT", "GROUP", "GSCLUSTER", "HAVING", "ILIKE", "IN", "INCREMENT",
        "INNER", "INSERT", "INTERSECT", "INTO", "IS", "ISSUE", "JOIN", "LATERAL", "LEFT", "LIKE", "LOCALTIME",
        "LOCALTIMESTAMP", "MINUS", "NATURAL", "NOT", "NULL", "OF", "ON", "OR", "ORDER", "ORGANIZATION", "QUALIFY",
        "REGEXP", "REVOKE", "RIGHT", "RLIKE", "ROW", "ROWS", "SAMPLE", "SCHEMA", "SELECT", "SET", "SOME", "START",
        "TABLE", "TABLESAMPLE", "THEN", "TO", "TRIGGER", "TRUE", "TRY_CAST", "UNION", "UNIQUE", "UPDATE", "USING",
        "VALUES", "VIEW", "WHEN", "WHENEVER", "WHERE", "WITH",
    ])
}
