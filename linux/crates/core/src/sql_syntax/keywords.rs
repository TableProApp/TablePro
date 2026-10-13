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

    /// Whether `name` reads as the same identifier written without
    /// quotes.
    ///
    /// PostgreSQL folds an unquoted name to lower case, so a capital
    /// changes the name there. A keyword the editor completes is quoted
    /// too, because most of them are reserved somewhere.
    pub fn is_bare_identifier(self, name: &str) -> bool {
        let mut chars = name.chars();
        let Some(first) = chars.next() else {
            return false;
        };
        let letter = |c: char| match self {
            Self::ClickHouse => c.is_ascii_alphabetic(),
            _ => c.is_alphabetic(),
        };
        let start = letter(first) || first == '_' || (self == Self::MsSql && first == '#');
        let part = |c: char| {
            letter(c)
                || c.is_ascii_digit()
                || c == '_'
                || (c == '$' && self != Self::ClickHouse)
                || (self == Self::MsSql && matches!(c, '#' | '@'))
        };
        let folds = self == Self::PostgreSql && name.chars().any(char::is_uppercase);
        start && chars.all(part) && !folds && !self.keywords().any(|keyword| keyword.eq_ignore_ascii_case(name))
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

    #[test]
    fn plain_names_stay_bare() {
        for grammar in SqlGrammar::ALL {
            assert!(grammar.is_bare_identifier("users"), "{grammar:?}");
            assert!(grammar.is_bare_identifier("order_items_2"), "{grammar:?}");
            assert!(grammar.is_bare_identifier("_draft"), "{grammar:?}");
        }
        assert!(SqlGrammar::PostgreSql.is_bare_identifier("đơn_hàng"));
        assert!(SqlGrammar::MySql.is_bare_identifier("Users"));
        assert!(SqlGrammar::MsSql.is_bare_identifier("#scratch"));
    }

    #[test]
    fn names_that_read_differently_bare_need_quotes() {
        for grammar in SqlGrammar::ALL {
            assert!(!grammar.is_bare_identifier(""), "{grammar:?}");
            assert!(!grammar.is_bare_identifier("order items"), "{grammar:?}");
            assert!(!grammar.is_bare_identifier("2fa"), "{grammar:?}");
            assert!(!grammar.is_bare_identifier("order"), "{grammar:?}");
            assert!(!grammar.is_bare_identifier("a-b"), "{grammar:?}");
        }
        assert!(!SqlGrammar::PostgreSql.is_bare_identifier("Users"));
        assert!(!SqlGrammar::PostgreSql.is_bare_identifier("user"));
        assert!(!SqlGrammar::ClickHouse.is_bare_identifier("đơn"));
        assert!(!SqlGrammar::ClickHouse.is_bare_identifier("a$b"));
    }
}
