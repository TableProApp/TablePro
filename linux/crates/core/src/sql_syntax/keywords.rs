use crate::sql_syntax::SqlGrammar;

const COMMON: &[&str] = &[
    "ADD",
    "ALL",
    "ALTER",
    "AND",
    "ANY",
    "AS",
    "ASC",
    "AVG",
    "BEGIN",
    "BETWEEN",
    "BY",
    "CASE",
    "CAST",
    "CHECK",
    "COALESCE",
    "COLUMN",
    "COMMIT",
    "CONSTRAINT",
    "COUNT",
    "CREATE",
    "CROSS",
    "DEFAULT",
    "DELETE",
    "DESC",
    "DISTINCT",
    "DROP",
    "ELSE",
    "END",
    "EXCEPT",
    "EXISTS",
    "FALSE",
    "FOREIGN",
    "FROM",
    "FULL",
    "GROUP",
    "HAVING",
    "IN",
    "INDEX",
    "INNER",
    "INSERT",
    "INTERSECT",
    "INTO",
    "IS",
    "JOIN",
    "KEY",
    "LEFT",
    "LIKE",
    "MAX",
    "MIN",
    "NOT",
    "NULL",
    "NULLIF",
    "ON",
    "OR",
    "ORDER",
    "OUTER",
    "PRIMARY",
    "REFERENCES",
    "RIGHT",
    "ROLLBACK",
    "SELECT",
    "SET",
    "SUM",
    "TABLE",
    "THEN",
    "TRUE",
    "TRUNCATE",
    "UNION",
    "UNIQUE",
    "UPDATE",
    "USING",
    "VALUES",
    "VIEW",
    "WHEN",
    "WHERE",
    "WITH",
];

const POSTGRESQL: &[&str] = &[
    "ANALYZE",
    "CONFLICT",
    "DO",
    "EXPLAIN",
    "ILIKE",
    "LATERAL",
    "LIMIT",
    "MATERIALIZED",
    "NOTHING",
    "OFFSET",
    "RETURNING",
    "SCHEMA",
    "SEQUENCE",
    "SIMILAR",
    "USER",
    "VACUUM",
];

const MYSQL: &[&str] = &[
    "AUTO_INCREMENT",
    "DATABASE",
    "DESCRIBE",
    "DUPLICATE",
    "EXPLAIN",
    "IGNORE",
    "LIMIT",
    "OFFSET",
    "REGEXP",
    "REPLACE",
    "SHOW",
    "USE",
];

const SQLITE: &[&str] = &[
    "ATTACH",
    "AUTOINCREMENT",
    "DETACH",
    "EXPLAIN",
    "GLOB",
    "IGNORE",
    "LIMIT",
    "OFFSET",
    "PRAGMA",
    "REPLACE",
    "RETURNING",
    "VACUUM",
    "WITHOUT",
];

const MSSQL: &[&str] = &[
    "DECLARE", "EXEC", "FETCH", "IDENTITY", "MERGE", "NEXT", "OFFSET", "ONLY", "OUTPUT", "ROWS", "TOP", "USE",
];

const CLICKHOUSE: &[&str] = &[
    "ARRAY", "DATABASE", "DESCRIBE", "ENGINE", "EXPLAIN", "FINAL", "FORMAT", "LIMIT", "OFFSET", "OPTIMIZE", "PREWHERE",
    "SAMPLE", "SETTINGS", "SHOW",
];

impl SqlGrammar {
    /// The keywords the editor completes for this grammar, in upper case.
    pub fn keywords(self) -> impl Iterator<Item = &'static str> {
        let own = match self {
            Self::PostgreSql => POSTGRESQL,
            Self::MySql => MYSQL,
            Self::Sqlite => SQLITE,
            Self::MsSql => MSSQL,
            Self::ClickHouse => CLICKHOUSE,
        };
        COMMON.iter().chain(own).copied()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn has(grammar: SqlGrammar, word: &str) -> bool {
        grammar.keywords().any(|keyword| keyword == word)
    }

    #[test]
    fn every_grammar_has_the_common_words_and_its_own() {
        for grammar in SqlGrammar::ALL {
            assert!(has(grammar, "SELECT"), "{grammar:?}");
        }
        assert!(has(SqlGrammar::PostgreSql, "RETURNING"));
        assert!(has(SqlGrammar::MsSql, "TOP"));
        assert!(!has(SqlGrammar::MsSql, "LIMIT"));
        assert!(has(SqlGrammar::ClickHouse, "PREWHERE"));
    }

    #[test]
    fn keywords_are_upper_case_and_listed_once() {
        for grammar in SqlGrammar::ALL {
            let mut seen = std::collections::HashSet::new();
            for keyword in grammar.keywords() {
                assert_eq!(keyword, keyword.to_ascii_uppercase());
                assert!(seen.insert(keyword), "{keyword} twice for {grammar:?}");
            }
        }
    }
}
